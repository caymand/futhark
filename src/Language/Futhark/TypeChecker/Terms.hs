{-# LANGUAGE GeneralizedNewtypeDeriving, FlexibleContexts #-}
-- | Facilities for type-checking Futhark terms.  Checking a term
-- requires a little more context to track uniqueness and such.
--
-- Type inference is implemented through a variation of
-- Hindler-Milney.  The main complication is supporting the rich
-- number of built-in language constructs, as well as uniqueness
-- types.  This is mostly done in an ad hoc way, and many programs
-- will require the programmer to fall back on type annotations.
module Language.Futhark.TypeChecker.Terms
  ( checkOneExp
  , checkFunDef
  )
where

import Control.Monad.Except
import Control.Monad.State
import Control.Monad.RWS
import qualified Control.Monad.Fail as Fail
import Data.List
import Data.Loc
import Data.Maybe
import qualified Data.Semigroup as Sem
import qualified Data.Map.Strict as M
import qualified Data.Set as S

import Prelude hiding (mod)

import Language.Futhark
import Language.Futhark.Traversals
import Language.Futhark.TypeChecker.Monad hiding (BoundV, checkQualNameWithEnv)
import Language.Futhark.TypeChecker.Types
import qualified Language.Futhark.TypeChecker.Monad as TypeM
import Futhark.Util.Pretty (Pretty)

--- Uniqueness

data Usage = Consumed SrcLoc
           | Observed SrcLoc
           deriving (Eq, Ord, Show)

data Occurence = Occurence { observed :: Names
                           , consumed :: Names
                           , location :: SrcLoc
                           }
             deriving (Eq, Show)

instance Located Occurence where
  locOf = locOf . location

observation :: Names -> SrcLoc -> Occurence
observation = flip Occurence S.empty

consumption :: Names -> SrcLoc -> Occurence
consumption = Occurence S.empty

nullOccurence :: Occurence -> Bool
nullOccurence occ = S.null (observed occ) && S.null (consumed occ)

type Occurences = [Occurence]

type UsageMap = M.Map VName [Usage]

usageMap :: Occurences -> UsageMap
usageMap = foldl comb M.empty
  where comb m (Occurence obs cons loc) =
          let m' = S.foldl' (ins $ Observed loc) m obs
          in S.foldl' (ins $ Consumed loc) m' cons
        ins v m k = M.insertWith (++) k [v] m

combineOccurences :: VName -> Usage -> Usage -> Either TypeError Usage
combineOccurences _ (Observed loc) (Observed _) = Right $ Observed loc
combineOccurences name (Consumed wloc) (Observed rloc) =
  Left $ UseAfterConsume (baseName name) rloc wloc
combineOccurences name (Observed rloc) (Consumed wloc) =
  Left $ UseAfterConsume (baseName name) rloc wloc
combineOccurences name (Consumed loc1) (Consumed loc2) =
  Left $ ConsumeAfterConsume (baseName name) (max loc1 loc2) (min loc1 loc2)

checkOccurences :: Occurences -> Either TypeError ()
checkOccurences = void . M.traverseWithKey comb . usageMap
  where comb _    []     = Right ()
        comb name (u:us) = foldM_ (combineOccurences name) u us

allObserved :: Occurences -> Names
allObserved = S.unions . map observed

allConsumed :: Occurences -> Names
allConsumed = S.unions . map consumed

allOccuring :: Occurences -> Names
allOccuring occs = allConsumed occs <> allObserved occs

seqOccurences :: Occurences -> Occurences -> Occurences
seqOccurences occurs1 occurs2 =
  filter (not . nullOccurence) $ map filt occurs1 ++ occurs2
  where filt occ =
          occ { observed = observed occ `S.difference` postcons }
        postcons = allConsumed occurs2

altOccurences :: Occurences -> Occurences -> Occurences
altOccurences occurs1 occurs2 =
  filter (not . nullOccurence) $ map filt1 occurs1 ++ map filt2 occurs2
  where filt1 occ =
          occ { consumed = consumed occ `S.difference` cons2
              , observed = observed occ `S.difference` cons2 }
        filt2 occ =
          occ { consumed = consumed occ
              , observed = observed occ `S.difference` cons1 }
        cons1 = allConsumed occurs1
        cons2 = allConsumed occurs2

--- Scope management

data ValBinding = BoundV [TypeParam] PatternType
                -- ^ Aliases in parameters indicate the lexical
                -- closure.
                | OverloadedF [PrimType] [Maybe PrimType] (Maybe PrimType)
                | EqualityF
                | OpaqueF
                | WasConsumed SrcLoc
                deriving (Show)

-- A piece of information that describes what process the type checker
-- currently performing.  This is used to give better error messages.
data BreadCrumb = MatchingTypes (TypeBase () ()) (TypeBase () ())

instance Show BreadCrumb where
  show (MatchingTypes t1 t2) =
    "When matching type `" ++ pretty t1 ++ "' with `" ++ pretty t2 ++ "'."

-- | Type checking happens with access to this environment.  The
-- tables will be extended during type-checking as bindings come into
-- scope.
data TermScope = TermScope { scopeVtable  :: M.Map VName ValBinding
                           , scopeTypeTable :: M.Map VName TypeBinding
                           , scopeNameMap :: NameMap
                           , scopeBreadCrumbs :: [BreadCrumb]
                             -- ^ Most recent first.
                           } deriving (Show)

instance Sem.Semigroup TermScope where
  TermScope vt1 tt1 nt1 bc1 <> TermScope vt2 tt2 nt2 bc2 =
    TermScope (vt2 `M.union` vt1) (tt2 `M.union` tt1) (nt2 `M.union` nt1) (bc1 <> bc2)

instance Monoid TermScope where
  mempty = TermScope mempty mempty mempty mempty
  mappend = (Sem.<>)

envToTermScope :: Env -> TermScope
envToTermScope env = TermScope vtable (envTypeTable env) (envNameMap env) mempty
  where vtable = M.map valBinding $ envVtable env
        valBinding (TypeM.BoundV tps v) = BoundV tps $ v `setAliases` mempty

-- | Mapping from fresh type variables, instantiated from the type
-- schemes of polymorphic functions, to (possibly) specific types as
-- determined on application and the location of that application, or
-- a partial constraint on their type.
type Constraints = M.Map VName Constraint

data Liftedness = Lifted -- ^ May be a function.
                | Unlifted -- ^ May not be a function.
                deriving Show

data Constraint = NoConstraint (Maybe Liftedness) SrcLoc
                | ParamType Liftedness SrcLoc
                | Constraint (TypeBase () ()) SrcLoc
                | Overloaded [PrimType] SrcLoc
                | Equality SrcLoc
                deriving Show

-- | Is the given type variable actually the name of an abstract type
-- or type parameter, which we cannot substitute?
isRigid :: VName -> Constraints -> Bool
isRigid v constraints = case M.lookup v constraints of
                             Nothing -> True
                             Just ParamType{} -> True
                             _ -> False

constraintSubsts :: Constraints -> M.Map VName (TypeBase () ())
constraintSubsts = M.mapMaybe constraintSubst
  where constraintSubst NoConstraint{} = Nothing
        constraintSubst ParamType{} = Nothing
        constraintSubst Overloaded{} = Nothing
        constraintSubst Equality{} = Nothing
        constraintSubst (Constraint t _) = Just t

applySubstInConstraint :: VName -> TypeBase () () -> Constraint -> Constraint
applySubstInConstraint vn tp (Constraint t loc) =
  Constraint (applySubst (M.singleton vn tp) t) loc
applySubstInConstraint _ _ (NoConstraint l loc) = NoConstraint l loc
applySubstInConstraint _ _ (Overloaded ts loc) = Overloaded ts loc
applySubstInConstraint _ _ (Equality loc) = Equality loc
applySubstInConstraint _ _ (ParamType l loc) = ParamType l loc

normaliseType :: Substitutable a => a -> TermTypeM a
normaliseType t = do subst <- gets constraintSubsts
                     return $ applySubst subst t

-- | Get the type of an expression, with all type variables
-- substituted.  Never call 'typeOf' directly (except in a few
-- carefully inspected locations)!
expType :: Exp -> TermTypeM CompType
expType = normaliseType . typeOf

newtype TermTypeM a = TermTypeM (RWST
                                 TermScope
                                 Occurences
                                 Constraints
                                 TypeM
                                 a)
  deriving (Monad, Functor, Applicative,
            MonadReader TermScope,
            MonadWriter Occurences,
            MonadState Constraints,
            MonadError TypeError)

instance Fail.MonadFail TermTypeM where
  fail = typeError noLoc . ("unknown failure (likely a bug): "++)

runTermTypeM :: TermTypeM a -> TypeM (a, Occurences)
runTermTypeM (TermTypeM m) = do
  initial_scope <- (initialTermScope <>) <$> (envToTermScope <$> askEnv)
  evalRWST m initial_scope mempty

liftTypeM :: TypeM a -> TermTypeM a
liftTypeM = TermTypeM . lift

initialTermScope :: TermScope
initialTermScope = TermScope initialVtable mempty topLevelNameMap mempty
  where initialVtable = M.fromList $ mapMaybe addIntrinsicF $ M.toList intrinsics

        funF ts t = foldr (Arrow mempty Nothing . Prim) (Prim t) ts

        addIntrinsicF (name, IntrinsicMonoFun ts t) =
          Just (name, BoundV [] $ funF ts t)
        addIntrinsicF (name, IntrinsicOverloadedFun ts pts rts) =
          Just (name, OverloadedF ts pts rts)
        addIntrinsicF (name, IntrinsicPolyFun tvs pts rt) =
          Just (name, BoundV tvs $
                      fromStruct $ vacuousShapeAnnotations $
                      Arrow mempty Nothing (tupleRecord pts) rt)
        addIntrinsicF (name, IntrinsicEquality) =
          Just (name, EqualityF)
        addIntrinsicF (name, IntrinsicOpaque) =
          Just (name, OpaqueF)
        addIntrinsicF _ = Nothing

instance MonadTypeChecker TermTypeM where
  warn loc problem = liftTypeM $ warn loc problem
  newName = liftTypeM . newName
  newID = liftTypeM . newID

  checkQualName space name loc = snd <$> checkQualNameWithEnv space name loc

  bindNameMap m = local $ \scope ->
    scope { scopeNameMap = m <> scopeNameMap scope }

  localEnv env (TermTypeM m) = do
    cur_state <- get
    cur_scope <- ask
    let cur_scope' =
          cur_scope { scopeNameMap = scopeNameMap cur_scope `M.difference` envNameMap env }
    (x,new_state,occs) <- liftTypeM $ localTmpEnv env $
                          runRWST m cur_scope' cur_state
    tell occs
    put new_state
    return x

  lookupType loc qn = do
    outer_env <- liftTypeM askRootEnv
    (scope, qn'@(QualName qs name)) <- checkQualNameWithEnv Type qn loc
    case M.lookup name $ scopeTypeTable scope of
      Nothing -> throwError $ UndefinedType loc qn
      Just (TypeAbbr ps def) ->
        return (qn', ps, qualifyTypeVars outer_env (map typeParamName ps) qs def)

  lookupMod loc name = liftTypeM $ TypeM.lookupMod loc name
  lookupMTy loc name = liftTypeM $ TypeM.lookupMTy loc name
  lookupImport loc name = liftTypeM $ TypeM.lookupImport loc name

  lookupVar loc qn = do
    outer_env <- liftTypeM askRootEnv
    (scope, qn'@(QualName qs name)) <- checkQualNameWithEnv Term qn loc
    case M.lookup name $ scopeVtable scope of
      Nothing -> throwError $ UnknownVariableError Term qn loc

      Just (WasConsumed wloc) -> throwError $ UseAfterConsume (baseName name) loc wloc

      Just (BoundV tparams t)
        | "_" `isPrefixOf` pretty name -> throwError $ UnderscoreUse loc qn
        | otherwise -> do
            (tnames, inst_list, t') <- instantiateTypeScheme loc tparams t
            let qual = qualifyTypeVars outer_env tnames qs
            t'' <- qual . removeShapeAnnotations <$> normaliseType t'
            return (qn', inst_list, t'')

      Just OpaqueF -> do
        argtype <- newTypeVar loc "t"
        return (qn', [], Arrow mempty Nothing argtype argtype)

      Just EqualityF -> do
        argtype <- newTypeVar loc "t"
        equalityType loc argtype
        return (qn', [toStruct argtype],
                Arrow mempty Nothing argtype $
                Arrow mempty Nothing argtype $ Prim Bool)

      Just (OverloadedF ts pts rt) -> do
        argtype <- newTypeVar loc "t"
        mustBeOneOf ts loc $ toStruct argtype
        let (pts', rt') = instOverloaded argtype pts rt
        return (qn', [toStruct argtype],
                fromStruct $ foldr (Arrow mempty Nothing) rt' pts')

      where instOverloaded argtype pts rt =
              (map (maybe (toStruct argtype) Prim) pts,
               maybe (toStruct argtype) Prim rt)

checkQualNameWithEnv :: Namespace -> QualName Name -> SrcLoc -> TermTypeM (TermScope, QualName VName)
checkQualNameWithEnv space qn@(QualName [q] _) loc
  | nameToString q == "intrinsics" = do
      -- Check if we are referring to the magical intrinsics
      -- module.
      (_, QualName _ q') <- liftTypeM $ TypeM.checkQualNameWithEnv Term (QualName [] q) loc
      if baseTag q' <= maxIntrinsicTag
        then checkIntrinsic space qn loc
        else checkReallyQualName space qn loc
checkQualNameWithEnv space qn@(QualName quals name) loc = do
  scope <- ask
  case quals of
    [] | Just name' <- M.lookup (space, name) $ scopeNameMap scope ->
           return (scope, name')
    _ -> checkReallyQualName space qn loc

checkIntrinsic :: Namespace -> QualName Name -> SrcLoc -> TermTypeM (TermScope, QualName VName)
checkIntrinsic space qn@(QualName _ name) loc
  | Just v <- M.lookup (space, name) intrinsicsNameMap = do
      scope <- ask
      return (scope, v)
  | otherwise =
      throwError $ UnknownVariableError space qn loc

checkReallyQualName :: Namespace -> QualName Name -> SrcLoc -> TermTypeM (TermScope, QualName VName)
checkReallyQualName space qn loc = do
  (env, name') <- liftTypeM $ TypeM.checkQualNameWithEnv space qn loc
  return (envToTermScope env, name')

-- | Instantiate a type scheme with fresh type variables for its type
-- parameters. Returns the names of the fresh type variables, the instance
-- list, and the instantiated type.
instantiateTypeScheme :: SrcLoc -> [TypeParam] -> PatternType
                      -> TermTypeM ([VName], [TypeBase () ()], PatternType)
instantiateTypeScheme loc tparams t = do
  let tparams' = filter isTypeParam tparams
      tnames = map typeParamName tparams'
  (fresh_tnames, inst_list) <- unzip <$> mapM (instantiateTypeParam loc) tparams'
  let substs = M.fromList $ zip tnames $
               map (vacuousShapeAnnotations . fromStruct) inst_list
      t' = substTypesAny substs t
  return (fresh_tnames, inst_list, t')

-- | Create a new type name and insert it (unconstrained) in the
-- substitution map.
instantiateTypeParam :: SrcLoc -> TypeParam -> TermTypeM (VName, TypeBase dim as)
instantiateTypeParam loc tparam = do
  v <- newName $ typeParamName tparam
  modify $ M.insert v $ NoConstraint (Just l) loc
  return (v, TypeVar (typeName v) [])
  where l = case tparam of TypeParamType{} -> Unlifted
                           _               -> Lifted

newTypeVar :: SrcLoc -> String -> TermTypeM (TypeBase dim als)
newTypeVar loc desc = do
  v <- newID $ nameFromString desc
  modify $ M.insert v $ NoConstraint Nothing loc
  return $ TypeVar (typeName v) []

newArrayType :: SrcLoc -> String -> Int -> TermTypeM (TypeBase () (), TypeBase () ())
newArrayType loc desc r = do
  v <- newID $ nameFromString desc
  modify $ M.insert v $ NoConstraint Nothing loc
  return (Array (ArrayPolyElem (typeName v) [] ())
                (ShapeDecl $ replicate r ()) Nonunique,
          TypeVar (typeName v) [])

breadCrumb :: BreadCrumb -> TermTypeM a -> TermTypeM a
breadCrumb bc = local $ \env ->
  env { scopeBreadCrumbs = bc : scopeBreadCrumbs env }

typeError :: SrcLoc -> String -> TermTypeM a
typeError loc s = do
  bc <- asks scopeBreadCrumbs
  let bc' | null bc = ""
          | otherwise = "\n" ++ unlines (map show bc)
  throwError $ TypeError loc $ s ++ bc'

--- Basic checking

-- | Determine if two types are identical, ignoring uniqueness.
-- Causes a 'TypeError' if they fail to match, and otherwise returns
-- one of them.
unifyExpTypes :: Exp -> Exp -> TermTypeM CompType
unifyExpTypes e1 e2 = do
  e1_t <- expType e1
  e2_t <- expType e2
  unify (srclocOf e2) (toStruct e1_t) (toStruct e2_t)
  return $ unifyTypeAliases e1_t e2_t

-- | Assumes that the two types have already been unified.
unifyTypeAliases :: CompType -> CompType -> CompType
unifyTypeAliases t1 t2 =
  case (t1, t2) of
    (Array et1 shape1 u1, Array et2 _ _) ->
      Array (unifyArrayElems et1 et2) shape1 u1
    (Record f1, Record f2) ->
      Record $ M.intersectionWith unifyTypeAliases f1 f2
    (TypeVar v targs1, TypeVar _ targs2) ->
      TypeVar v $ zipWith unifyTypeArg targs1 targs2
    _ -> t1
  where unifyArrayElems (ArrayPrimElem pt1 als1) (ArrayPrimElem _ als2) =
          ArrayPrimElem pt1 $ als1 <> als2
        unifyArrayElems (ArrayPolyElem v targs1 als1) (ArrayPolyElem _ targs2 als2) =
          ArrayPolyElem v (zipWith unifyTypeArg targs1 targs2) $ als1 <> als2
        unifyArrayElems (ArrayRecordElem fields1) (ArrayRecordElem fields2) =
          ArrayRecordElem $ M.intersectionWith unifyRecordArray fields1 fields2
        unifyArrayElems x _ = x

        unifyRecordArray (RecordArrayElem at1) (RecordArrayElem at2) =
          RecordArrayElem $ unifyArrayElems at1 at2
        unifyRecordArray (RecordArrayArrayElem at1 shape1 u) (RecordArrayArrayElem at2 _ _) =
          RecordArrayArrayElem (unifyArrayElems at1 at2) shape1 u
        unifyRecordArray x _ = x

        unifyTypeArg (TypeArgType t1' loc) (TypeArgType t2' _) =
          TypeArgType (unifyTypeAliases t1' t2') loc
        unifyTypeArg a _ = a

--- General binding.

data InferredType = NoneInferred
                  | Inferred CompType
                  | Ascribed PatternType


checkPattern' :: UncheckedPattern -> InferredType
              -> TermTypeM Pattern

checkPattern' (PatternParens p loc) t =
  PatternParens <$> checkPattern' p t <*> pure loc

checkPattern' (Id name NoInfo loc) (Inferred t) = do
  name' <- checkName Term name loc
  let t' = vacuousShapeAnnotations $
           case t of Record{} -> t
                     _        -> t `addAliases` S.insert name'
  return $ Id name' (Info $ t' `setUniqueness` Nonunique) loc
checkPattern' (Id name NoInfo loc) (Ascribed t) = do
  name' <- checkName Term name loc
  let t' = case t of Record{} -> t
                     _        -> t `addAliases` S.insert name'
  return $ Id name' (Info t') loc
checkPattern' (Id name NoInfo loc) NoneInferred = do
  name' <- checkName Term name loc
  t <- newTypeVar loc "t"
  return $ Id name' (Info t) loc

checkPattern' (Wildcard _ loc) (Inferred t) =
  return $ Wildcard (Info $ vacuousShapeAnnotations $ t `setUniqueness` Nonunique) loc
checkPattern' (Wildcard _ loc) (Ascribed t) =
  return $ Wildcard (Info $ t `setUniqueness` Nonunique) loc
checkPattern' (Wildcard NoInfo loc) NoneInferred = do
  t <- newTypeVar loc "t"
  return $ Wildcard (Info t) loc

checkPattern' (TuplePattern ps loc) (Inferred t)
  | Just ts <- isTupleRecord t, length ts == length ps =
      TuplePattern <$> zipWithM checkPattern' ps (map Inferred ts) <*> pure loc
checkPattern' (TuplePattern ps loc) (Ascribed t)
  | Just ts <- isTupleRecord t, length ts == length ps =
      TuplePattern <$> zipWithM checkPattern' ps (map Ascribed ts) <*> pure loc
checkPattern' p@TuplePattern{} (Inferred t) =
  typeError (srclocOf p) $ "Pattern " ++ pretty p ++ " cannot match " ++ pretty t
checkPattern' p@TuplePattern{} (Ascribed t) =
  typeError (srclocOf p) $ "Pattern " ++ pretty p ++ " cannot match " ++ pretty t
checkPattern' (TuplePattern ps loc) NoneInferred =
  TuplePattern <$> mapM (`checkPattern'` NoneInferred) ps <*> pure loc

checkPattern' (RecordPattern p_fs loc) (Inferred (Record t_fs))
  | sort (map fst p_fs) == sort (M.keys t_fs) =
    RecordPattern . M.toList <$> check <*> pure loc
    where check = traverse (uncurry checkPattern') $ M.intersectionWith (,)
                  (M.fromList p_fs) (fmap Inferred t_fs)
checkPattern' (RecordPattern p_fs loc) (Ascribed (Record t_fs))
  | sort (map fst p_fs) == sort (M.keys t_fs) =
    RecordPattern . M.toList <$> check <*> pure loc
    where check = traverse (uncurry checkPattern') $ M.intersectionWith (,)
                  (M.fromList p_fs) (fmap Ascribed t_fs)
checkPattern' p@RecordPattern{} (Inferred t) =
  typeError (srclocOf p) $ "Pattern " ++ pretty p ++ " cannot match " ++ pretty t
checkPattern' p@RecordPattern{} (Ascribed t) =
  typeError (srclocOf p) $ "Pattern " ++ pretty p ++ " cannot match " ++ pretty t
checkPattern' (RecordPattern fs loc) NoneInferred =
  RecordPattern . M.toList <$> traverse (`checkPattern'` NoneInferred) (M.fromList fs) <*> pure loc

checkPattern' fullp@(PatternAscription p (TypeDecl t NoInfo)) maybe_outer_t = do
  (t', st) <- checkTypeExp t

  let maybe_outer_t' = case maybe_outer_t of
                         Inferred outer_t -> Just $ vacuousShapeAnnotations outer_t
                         Ascribed outer_t -> Just outer_t
                         NoneInferred -> Nothing
      st' = fromStruct st
  case maybe_outer_t' of
    Just outer_t
      | Just t'' <- unifyTypesU unifyUniqueness st' outer_t ->
          PatternAscription <$> checkPattern' p (Ascribed t'') <*>
          pure (TypeDecl t' (Info st))
      | otherwise ->
          let outer_t_for_error =
                modifyShapeAnnotations (fmap baseName) $ outer_t `setAliases` ()
          in throwError $ InvalidPatternError fullp outer_t_for_error Nothing $ srclocOf p
    _ -> PatternAscription <$> checkPattern' p (Ascribed st') <*>
         pure (TypeDecl t' (Info st))
  where unifyUniqueness u1 u2 = if u2 `subuniqueOf` u1 then Just u1 else Nothing

bindPatternNames :: PatternBase NoInfo Name -> TermTypeM a -> TermTypeM a
bindPatternNames = bindSpaced . map asTerm . S.toList . patIdentSet
  where asTerm v = (Term, identName v)

checkPattern :: UncheckedPattern -> InferredType -> (Pattern -> TermTypeM a)
             -> TermTypeM a
checkPattern p t m = do
  checkForDuplicateNames [p]
  bindPatternNames p $
    m =<< checkPattern' p t

binding :: [Ident] -> TermTypeM a -> TermTypeM a
binding bnds = check . local (`bindVars` bnds)
  where bindVars :: TermScope -> [Ident] -> TermScope
        bindVars = foldl bindVar

        bindVar :: TermScope -> Ident -> TermScope
        bindVar scope (Ident name (Info tp) _) =
          let inedges = S.toList $ aliases tp
              update (BoundV tparams tp')
              -- If 'name' is record-typed, don't alias the components
              -- to 'name', because records have no identity beyond
              -- their components.
                | Record _ <- tp = BoundV tparams tp'
                | otherwise = BoundV tparams (tp' `addAliases` S.insert name)
              update b = b
          in scope { scopeVtable = M.insert name (BoundV [] $ vacuousShapeAnnotations tp) $
                                   adjustSeveral update inedges $
                                   scopeVtable scope
                   }

        adjustSeveral f = flip $ foldl $ flip $ M.adjust f

        -- Check whether the bound variables have been used correctly
        -- within their scope.
        check m = do
          (a, usages) <- collectBindingsOccurences m
          maybeCheckOccurences usages

          mapM_ (checkIfUsed usages) bnds

          return a

        -- Collect and remove all occurences in @bnds@.  This relies
        -- on the fact that no variables shadow any other.
        collectBindingsOccurences m = pass $ do
          (x, usage) <- listen m
          let (relevant, rest) = split usage
          return ((x, relevant), const rest)
          where split = unzip .
                        map (\occ ->
                             let (obs1, obs2) = divide $ observed occ
                                 (con1, con2) = divide $ consumed occ
                             in (occ { observed = obs1, consumed = con1 },
                                 occ { observed = obs2, consumed = con2 }))
                names = S.fromList $ map identName bnds
                divide s = (s `S.intersection` names, s `S.difference` names)

bindingTypes :: [(VName, (TypeBinding, Constraint))] -> TermTypeM a -> TermTypeM a
bindingTypes types m = do
  modify (<>M.map snd (M.fromList types))
  local extend m
  where extend scope = scope {
          scopeTypeTable = M.map fst (M.fromList types) <> scopeTypeTable scope
          }

bindingTypeParams :: [TypeParam] -> TermTypeM a -> TermTypeM a
bindingTypeParams tparams = binding (mapMaybe typeParamIdent tparams) .
                            bindingTypes (mapMaybe typeParamType tparams)
  where typeParamType (TypeParamType v loc) =
          Just (v, (TypeAbbr [] (TypeVar (typeName v) []),
                    ParamType Unlifted loc))
        typeParamType (TypeParamLiftedType v loc) =
          Just (v, (TypeAbbr [] (TypeVar (typeName v) []),
                    ParamType Lifted loc))
        typeParamType TypeParamDim{} =
          Nothing

typeParamIdent :: TypeParam -> Maybe Ident
typeParamIdent (TypeParamDim v loc) =
  Just $ Ident v (Info (Prim (Signed Int32))) loc
typeParamIdent _ = Nothing

bindingIdent :: IdentBase NoInfo Name -> CompType -> (Ident -> TermTypeM a)
             -> TermTypeM a
bindingIdent (Ident v NoInfo vloc) t m =
  bindSpaced [(Term, v)] $ do
    v' <- checkName Term v vloc
    let ident = Ident v' (Info t) vloc
    binding [ident] $ m ident

bindingPatternGroup :: [UncheckedTypeParam]
                    -> [(UncheckedPattern, InferredType)]
                    -> ([TypeParam] -> [Pattern] -> TermTypeM a) -> TermTypeM a
bindingPatternGroup tps orig_ps m = do
  checkForDuplicateNames $ map fst orig_ps
  checkTypeParams tps $ \tps' -> bindingTypeParams tps' $ do
    let descend ps' ((p,t):ps) =
          checkPattern p t $ \p' ->
            binding (S.toList $ patIdentSet p') $ descend (p':ps') ps
        descend ps' [] = do
          -- Perform an observation of every type parameter.  This
          -- prevents unused-name warnings for otherwise unused
          -- dimensions.
          mapM_ observe $ mapMaybe typeParamIdent tps'
          checkTypeParamsUsed tps' ps'

          m tps' $ reverse ps'

    descend [] orig_ps

bindingPattern :: [UncheckedTypeParam]
               -> PatternBase NoInfo Name -> InferredType
               -> ([TypeParam] -> Pattern -> TermTypeM a) -> TermTypeM a
bindingPattern tps p t m = do
  checkForDuplicateNames [p]
  checkTypeParams tps $ \tps' -> bindingTypeParams tps' $
    checkPattern p t $ \p' -> binding (S.toList $ patIdentSet p') $ do
      -- Perform an observation of every declared dimension.  This
      -- prevents unused-name warnings for otherwise unused dimensions.
      mapM_ observe $ patternDims p'
      checkTypeParamsUsed tps' [p']

      m tps' p'

checkTypeParamsUsed :: [TypeParam] -> [Pattern] -> TermTypeM ()
checkTypeParamsUsed tps ps = mapM_ check tps
  where uses = mconcat $ map patternUses ps
        check (TypeParamDim pv loc)
          | qualName pv `elem` patternDimUses uses = return ()
          | otherwise =
              typeError loc $
              "Size parameter " ++ pretty (baseName pv) ++
              " not used in value parameters."
        check _ = return ()

noTypeParamsPermitted :: [UncheckedTypeParam] -> TermTypeM ()
noTypeParamsPermitted ps =
  case mapMaybe typeParamLoc ps of
    loc:_ -> typeError loc "Type parameters are not permitted here."
    []    -> return ()
  where typeParamLoc (TypeParamDim _ _) = Nothing
        typeParamLoc tparam             = Just $ srclocOf tparam

patternDims :: Pattern -> [Ident]
patternDims (PatternParens p _) = patternDims p
patternDims (TuplePattern pats _) = concatMap patternDims pats
patternDims (PatternAscription p (TypeDecl _ (Info t))) =
  patternDims p <> mapMaybe (dimIdent (srclocOf p)) (nestedDims t)
  where dimIdent _ AnyDim            = Nothing
        dimIdent _ (ConstDim _)      = Nothing
        dimIdent _ NamedDim{}        = Nothing
patternDims _ = []

data PatternUses = PatternUses { patternDimUses :: [QualName VName]
                               , _patternTypeUses :: [QualName VName]
                               }

instance Sem.Semigroup PatternUses where
  PatternUses x1 y1 <> PatternUses x2 y2 =
    PatternUses (x1<>x2) (y1<>y2)

instance Monoid PatternUses where
  mempty = PatternUses mempty mempty
  mappend = (Sem.<>)

patternUses :: Pattern -> PatternUses
patternUses Id{} = mempty
patternUses Wildcard{} = mempty
patternUses (PatternParens p _) = patternUses p
patternUses (TuplePattern ps _) = mconcat $ map patternUses ps
patternUses (RecordPattern fs _) = mconcat $ map (patternUses . snd) fs
patternUses (PatternAscription p (TypeDecl declte _)) =
  patternUses p <> typeExpUses declte
  where typeExpUses (TEVar qn _) = PatternUses [] [qn]
        typeExpUses (TETuple tes _) = mconcat $ map typeExpUses tes
        typeExpUses (TERecord fs _) = mconcat $ map (typeExpUses . snd) fs
        typeExpUses (TEArray te d _) = typeExpUses te <> dimDeclUses d
        typeExpUses (TEUnique te _) = typeExpUses te
        typeExpUses (TEApply te targ _) = typeExpUses te <> typeArgUses targ
        typeExpUses (TEArrow _ t1 t2 _) = typeExpUses t1 <> typeExpUses t2

        typeArgUses (TypeArgExpDim d _) = dimDeclUses d
        typeArgUses (TypeArgExpType te) = typeExpUses te

        dimDeclUses (NamedDim v) = PatternUses [v] []
        dimDeclUses _ = mempty

--- Main checkers

-- | @require ts e@ causes a 'TypeError' if @expType e@ is not one of
-- the types in @ts@.  Otherwise, simply returns @e@.
require :: [PrimType] -> Exp -> TermTypeM Exp
require ts e = do mustBeOneOf ts (srclocOf e) . toStruct =<< expType e
                  return e

unifies :: TypeBase () () -> Exp -> TermTypeM Exp
unifies t e = do
  unify (srclocOf e) t =<< toStruct <$> expType e
  return e

checkExp :: UncheckedExp -> TermTypeM Exp

checkExp (Literal val loc) =
  return $ Literal val loc

checkExp (TupLit es loc) =
  TupLit <$> mapM checkExp es <*> pure loc

checkExp (RecordLit fs loc) = do
  -- It is easy for programmers to forget that record literals are
  -- right-biased.  Hence, emit a warning if we encounter literal
  -- fields whose values would never be used.

  fs' <- evalStateT (mapM checkField fs) mempty

  return $ RecordLit fs' loc
  where checkField (RecordFieldExplicit f e rloc) = do
          errIfAlreadySet f rloc
          modify $ M.insert f rloc
          RecordFieldExplicit f <$> lift (checkExp e) <*> pure rloc
        checkField (RecordFieldImplicit name NoInfo rloc) = do
          errIfAlreadySet name rloc
          (QualName _ name', _, t) <- lift $ lookupVar rloc $ qualName name
          modify $ M.insert name rloc
          lift $ observe $ Ident name' (Info t) rloc
          return $ RecordFieldImplicit name' (Info t) rloc

        errIfAlreadySet f rloc = do
          maybe_sloc <- gets $ M.lookup f
          case maybe_sloc of
            Just sloc ->
              lift $ typeError rloc $ "Field '" ++ pretty f ++
              " previously defined at " ++ locStr sloc ++ "."
            Nothing -> return ()

checkExp (ArrayLit es _ loc) = do
  -- Construct the result type and unify all elements with it.
  et <- newTypeVar loc "t"
  t <- arrayOfM loc et (rank 1) Unique
  es' <- forM es $ \e -> do
    e' <- checkExp e
    unify (srclocOf e') (toStructural et) . toStructural =<< expType e'
    return e'
  return $ ArrayLit es' (Info t) loc

checkExp (Range start maybe_step end NoInfo loc) = do
  start' <- require anyIntType =<< checkExp start
  start_t <- toStructural <$> expType start'
  maybe_step' <- case maybe_step of
    Nothing -> return Nothing
    Just step -> do
      let warning = warn loc "First and second element of range are identical, this will produce an empty array."
      case (start, step) of
        (Literal x _, Literal y _) -> when (x == y) warning
        (Var x_name _ _, Var y_name _ _) -> when (x_name == y_name) warning
        _ -> return ()
      Just <$> (unifies start_t =<< checkExp step)

  end' <- case end of
    DownToExclusive e -> DownToExclusive <$> (unifies start_t =<< checkExp e)
    UpToExclusive e -> UpToExclusive <$> (unifies start_t =<< checkExp e)
    ToInclusive e -> ToInclusive <$> (unifies start_t =<< checkExp e)

  t <- arrayOfM loc start_t (rank 1) Unique

  return $ Range start' maybe_step' end' (Info (t `setAliases` mempty)) loc

checkExp (Empty decl NoInfo loc) = do
  decl' <- checkTypeDecl decl
  t <- arrayOfM loc (removeShapeAnnotations $ unInfo $ expandedType decl') (rank 1) Unique
  return $ Empty decl' (Info $ t `setAliases` mempty) loc

checkExp (Ascript e decl loc) = do
  decl' <- checkTypeDecl decl
  e' <- checkExp e
  t <- toStruct <$> expType e'
  let decl_t = removeShapeAnnotations $ unInfo $ expandedType decl'
  unify loc decl_t t

  -- We also have to make sure that uniqueness matches.  This is done
  -- explicitly, because uniqueness is ignored by unification.
  t' <- normaliseType t
  decl_t' <- normaliseType decl_t
  unless (t' `subtypeOf` decl_t') $
    typeError loc $ "Type \"" ++ pretty t' ++ " is not a subtype of \"" ++
    pretty decl_t' ++ "\"."

  return $ Ascript e' decl' loc

checkExp (BinOp op NoInfo (e1,_) (e2,_) NoInfo loc) = do
  (e1', e1_arg) <- checkArg e1
  (e2', e2_arg) <- checkArg e2

  (op', il, ftype) <- lookupVar loc op

  (e1_pt : e2_pt : pts, rettype') <-
    checkFuncall loc ftype [e1_arg, e2_arg]
  return $ BinOp op' (Info il) (e1', Info e1_pt) (e2', Info e2_pt)
    (Info (pts, rettype')) loc

checkExp (Project k e NoInfo loc) = do
  e' <- checkExp e
  t <- expType e'
  case t of
    Record fs | Just kt <- M.lookup k fs ->
                return $ Project k e' (Info kt) loc
    _ -> throwError $ InvalidField loc t (pretty k)

checkExp (If e1 e2 e3 _ loc) =
  sequentially checkCond $ \e1' _ -> do
  ((e2', e3'), dflow) <- tapOccurences $ checkExp e2 `alternative` checkExp e3
  brancht <- unifyExpTypes e2' e3'
  let t' = addAliases brancht (`S.difference` allConsumed dflow)
  zeroOrderType loc "returned from branch" t'
  return $ If e1' e2' e3' (Info t') loc
  where checkCond = do
          e1' <- checkExp e1
          unify (srclocOf e1') (Prim Bool) . toStruct =<< expType e1'
          return e1'

checkExp (Parens e loc) =
  Parens <$> checkExp e <*> pure loc

checkExp (QualParens modname e loc) = do
  (modname',mod) <- lookupMod loc modname
  case mod of
    ModEnv env -> localEnv (qualifyEnv modname' env) $ do
      e' <- checkExp e
      return $ QualParens modname' e' loc
    ModFun{} ->
      typeError loc $ "Module " ++ pretty modname ++ " is a parametric module."
  where qualifyEnv modname' env =
          env { envNameMap = M.map (qualify' modname') $ envNameMap env }
        qualify' modname' (QualName qs name) =
          QualName (qualQuals modname' ++ [qualLeaf modname'] ++ qs) name

checkExp (Var qn NoInfo loc) = do
  -- The qualifiers of a variable is divided into two parts: first a
  -- possibly-empty sequence of module qualifiers, followed by a
  -- possible-empty sequence of record field accesses.  We use scope
  -- information to perform the split, by taking qualifiers off the
  -- end until we find a module.

  (qn', il, t, fields) <- findRootVar (qualQuals qn) (qualLeaf qn)
  observe $ Ident (qualLeaf qn') (Info t) loc
  let (ps, ret) = unfoldFunType t
      ps' = map (vacuousShapeAnnotations . toStruct) ps

  foldM checkField (Var qn' (Info (il, ps', ret)) loc) fields
  where findRootVar qs name = do
          r <- (Right <$> lookupVar loc (QualName qs name))
               `catchError` handler
          case r of
            Left err | null qs -> throwError err
                     | otherwise -> do
                         (qn', il, t, fields) <- findRootVar (init qs) (last qs)
                         return (qn', il, t, fields++[name])
            Right (qn', il, t) -> return (qn', il, t, [])

        handler (UnknownVariableError ns qn' _)
          | null (qualQuals qn') = return . Left $ UnknownVariableError ns qn loc
        handler e = return $ Left e

        checkField e k = do
          t <- expType e
          case t of
            Record fs | Just kt <- M.lookup k fs ->
                        return $ Project k e (Info kt) loc
            _ -> throwError $ InvalidField loc t (pretty k)

checkExp (Negate arg loc) = do
  arg' <- require anyNumberType =<< checkExp arg
  return $ Negate arg' loc

checkExp (Apply e1 e2 NoInfo NoInfo loc) = do
  (e2', arg) <- checkArg e2
  case e1 of
    Var qn _ var_loc -> do
      r <- (Right <$> lookupVar loc qn) `catchError` (return . Left)
      case r of
        Right (fname, il, ftype) -> do
          let ftype' = removeShapeAnnotations ftype
          (paramtypes@(t1 : rest), rettype) <- checkApply loc ftype' arg
          return $ Apply (Var fname (Info (il, paramtypes, rettype)) var_loc)
                   e2' (Info $ diet t1) (Info (rest, rettype)) loc

        -- Even if the function lookup failed, the applied expression
        -- may still be a record projection of a function.
        Left _ -> checkGeneralApp e2' arg

    _ -> checkGeneralApp e2' arg

  where checkGeneralApp e2' arg = do
          e1' <- checkExp e1
          t <- expType e1'
          (t1 : paramtypes, rettype) <- checkApply loc t arg
          return $ Apply e1' e2' (Info $ diet t1)
                   (Info (paramtypes, rettype)) loc

checkExp (LetPat tparams pat e body pos) = do
  noTypeParamsPermitted tparams
  sequentially (checkExp e) $ \e' _ -> do
    -- Not technically an ascription, but we want the pattern to have
    -- exactly the type of 'e'.
    t <- expType e'
    bindingPattern tparams pat (Ascribed $ vacuousShapeAnnotations t) $ \tparams' pat' -> do
      body' <- checkExp body
      return $ LetPat tparams' pat' e' body' pos

checkExp (LetFun name (tparams, params, maybe_retdecl, NoInfo, e) body loc) =
  bindSpaced [(Term, name)] $
  sequentially (checkFunDef' (name, maybe_retdecl, tparams, params, e, loc)) $
    \(name', tparams', params', maybe_retdecl', rettype, e') closure -> do

    let ftype = foldr (uncurry (Arrow ()) . patternParam) rettype params'
        entry = BoundV tparams' $ ftype `setAliases` allOccuring closure
        bindF scope = scope { scopeVtable = M.insert name' entry $ scopeVtable scope }
    body' <- local bindF $ checkExp body

    return $ LetFun name' (tparams', params', maybe_retdecl', Info rettype, e') body' loc

checkExp (LetWith dest src idxes ve body pos) = do
  src' <- checkIdent src

  unless (unique $ unInfo $ identType src') $
    typeError pos $ "Source '" ++ pretty (identName src) ++
    "' has type " ++ pretty (unInfo $ identType src') ++ ", which is not unique"

  idxes' <- mapM checkDimIndex idxes
  case peelArray (length $ filter isFix idxes') (unInfo $ identType src') of
    Nothing -> throwError $ IndexingError
               (arrayRank $ unInfo $ identType src') (length idxes) (srclocOf src)
    Just elemt -> do
      let elemt' = toStructural elemt `setUniqueness` Nonunique
      sequentially (unifies elemt' =<< checkExp ve) $ \ve' _ -> do
        ve_t <- expType ve'
        when (identName src' `S.member` aliases ve_t) $
          throwError $ BadLetWithValue pos

        bindingIdent dest (unInfo (identType src') `setAliases` S.empty) $ \dest' -> do
          body' <- consuming src' $ checkExp body
          return $ LetWith dest' src' idxes' ve' body' pos
  where isFix DimFix{} = True
        isFix _        = False

checkExp (Update src idxes ve loc) =
  sequentially (checkExp src) $ \src' _ -> do
    src_t <- expType src'
    let src_als = aliases src_t

    unless (unique src_t) $
      typeError loc $ "Source '" ++ pretty src ++
      "' has type " ++ pretty src_t ++ ", which is not unique"

    idxes' <- mapM checkDimIndex idxes
    case peelArray (length $ filter isFix idxes') src_t of
      Nothing -> throwError $ IndexingError (arrayRank src_t) (length idxes) (srclocOf src)
      Just elemt -> do
        ve' <- unifies (toStructural elemt) =<< checkExp ve
        ve_t <- expType ve'
        unless (S.null $ src_als `S.intersection` aliases ve_t) $
          throwError $ BadLetWithValue loc

        consume loc src_als
        return $ Update src' idxes' ve' loc
  where isFix DimFix{} = True
        isFix _        = False

checkExp (Index e idxes NoInfo loc) = do
  (t, _) <- newArrayType (srclocOf e) "e" $ length idxes
  e' <- unifies t =<< checkExp e
  idxes' <- mapM checkDimIndex idxes
  t' <- stripArray (length $ filter isFix idxes) <$> normaliseType (typeOf e')
  return $ Index e' idxes' (Info t') loc
  where isFix DimFix{} = True
        isFix _        = False

checkExp (Reshape shapeexp arrexp NoInfo loc) = do
  shapeexp' <- checkExp shapeexp
  arrexp' <- checkExp arrexp
  shape_t <- expType shapeexp'
  arr_t <- expType arrexp'

  case shape_t of
    t | Just ts <- isTupleRecord t,
        all ((`elem` map Prim anyIntType) . toStruct) ts -> return ()
    Prim Signed{} -> return ()
    Prim Unsigned{} -> return ()
    t -> typeError loc $ "Shape argument " ++ pretty shapeexp ++
      " to reshape must be integer or tuple of integers, but is " ++ pretty t

  case arr_t of
    Array{} -> return ()
    t -> typeError loc $
         "Array argument to reshape must be an array, but has type " ++ pretty t

  return $ Reshape shapeexp' arrexp' (Info arr_t) loc

checkExp (Rearrange perm arrexp pos) = do
  arrexp' <- checkExp arrexp
  r <- arrayRank <$> expType arrexp'
  when (length perm /= r || sort perm /= [0..r-1]) $
    throwError $ PermutationError pos perm r
  return $ Rearrange perm arrexp' pos

checkExp (Rotate d offexp arrexp loc) = do
  arrexp' <- checkExp arrexp
  offexp' <- unifies (Prim $ Signed Int32) =<< checkExp offexp
  r <- arrayRank <$> expType arrexp'
  when (r <= d) $
    typeError loc $ "Attempting to rotate dimension " ++ show d ++
    " of array " ++ pretty arrexp ++
    " which has only " ++ show r ++ " dimensions."
  return $ Rotate d offexp' arrexp' loc

checkExp (Zip i e es NoInfo loc) = do
  let checkInput inp = do (arr_t, _) <- newArrayType (srclocOf e) "e" (1+i)
                          unifies arr_t =<< checkExp inp
  e' <- checkInput e
  es' <- mapM checkInput es

  ts <- forM (e':es') $ \arr_e -> do
    arr_e_t <- expType arr_e
    case typeToRecordArrayElem' (aliases arr_e_t) =<< peelArray (i+1) arr_e_t of
      Just t -> return t
      Nothing -> typeError (srclocOf arr_e) $
                 "Expected array with at least " ++ show (1+i) ++
                 " dimensions, but got " ++ pretty arr_e_t ++ "."

  let u = mconcat $ map (uniqueness . typeOf) $ e':es'
      t = Array (ArrayRecordElem $ M.fromList $ zip tupleFieldNames ts)
                (rank (1+i)) u
  return $ Zip i e' es' (Info t) loc

checkExp (Unzip e _ loc) = do
  e' <- checkExp e
  e_t <- expType e'
  case e_t of
    Array (ArrayRecordElem fs) shape u
      | Just ets <- map (componentType shape u) <$> areTupleFields fs ->
          return $ Unzip e' (map Info ets) loc
    t ->
      typeError loc $
      "Argument to unzip is not an array of tuples, but " ++
      pretty t ++ "."
  where componentType shape u et =
          case et of
            RecordArrayElem et' ->
              Array et' shape u
            RecordArrayArrayElem et' et_shape et_u ->
              Array et' (shape <> et_shape) (u `max` et_u)

checkExp (Unsafe e loc) =
  Unsafe <$> checkExp e <*> pure loc

checkExp (Map fun arrexps NoInfo loc) = do
  (arrexps', args) <- unzip <$> mapM checkSOACArrayArg arrexps
  (fun', rt) <- checkFunExp fun args
  t <- arrayOfM loc rt (rank 1) Unique
  return $ Map fun' arrexps' (Info $ t `setAliases` mempty) loc

checkExp Reduce{} = error "Reduce nodes should not appear in source program"
checkExp Scan{} = error "Scan nodes should not appear in source program"
checkExp Filter{} = error "Filter nodes should not appear in source program"
checkExp Stream{} = error "Stream nodes should not appear in source program"

checkExp (Partition funs arrexp pos) = do
  (arrexp', (rowelemt, argflow, argloc)) <- checkSOACArrayArg arrexp
  let nonunique_arg = (rowelemt `setUniqueness` Nonunique,
                       argflow, argloc)
  funs' <- forM funs $ \fun -> do
    (fun', fun_t) <- checkFunExp fun [nonunique_arg]
    when (fun_t /= Prim Bool) $
      typeError (srclocOf fun') "Partition function does not return bool."
    return fun'

  return $ Partition funs' arrexp' pos

checkExp (Concat i arr1exp arr2exps loc) = do
  arr1exp'  <- checkExp arr1exp
  let arr1_t = toStructural (typeOf arr1exp') `setUniqueness` Nonunique
  arr2exps' <- mapM (unifies arr1_t <=< checkExp) arr2exps
  mapM_ ofProperRank arr2exps'
  return $ Concat i arr1exp' arr2exps' loc
  where ofProperRank e
          | arrayRank t <= i =
              typeError loc $ "Cannot concat array " ++ pretty e
              ++ " of type " ++ pretty t
              ++ " across dimension " ++ pretty i ++ "."
          | otherwise = return ()
          where t = typeOf e

checkExp (Lambda tparams params body maybe_retdecl NoInfo loc) =
  bindingPatternGroup tparams (zip params $ repeat NoneInferred) $ \tparams' params' -> do
    maybe_retdecl' <- traverse checkTypeDecl maybe_retdecl
    body' <- checkFunBody body (unInfo . expandedType <$> maybe_retdecl') loc
    (maybe_retdecl'', rettype) <- case maybe_retdecl' of
      Just retdecl'@(TypeDecl _ (Info st)) -> return (Just retdecl', st)
      Nothing -> do
        body_t <- expType body'
        return (Nothing, vacuousShapeAnnotations $ toStruct body_t)
    return $ Lambda tparams' params' body' maybe_retdecl'' (Info rettype) loc

checkExp (OpSection op _ _ _ _ loc) = do
  (op', il, ftype) <- lookupVar loc op
  let (paramtypes, rettype) = unfoldFunType ftype
  case paramtypes of
    t1 : t2 : rest -> do
      let t1' = vacuousShapeAnnotations $ toStruct t1
          t2' = vacuousShapeAnnotations $ toStruct t2
      return $ OpSection op' (Info il) (Info t1') (Info t2')
                 (Info $ foldr (Arrow mempty Nothing) rettype rest ) loc
    _ -> typeError loc $
         "Operator section with invalid operator of type " ++ pretty ftype

checkExp (OpSectionLeft op _ e _ _ loc) = do
  (op', il, ftype) <- lookupVar loc op
  (e', e_arg) <- checkArg e
  (paramtypes, rettype) <- checkApply loc ftype e_arg
  case paramtypes of
    t1 : t2 : rest ->
      let rettype' = foldr (Arrow mempty Nothing .
                             removeShapeAnnotations . fromStruct) rettype rest
      in return $ OpSectionLeft op' (Info il) e' (Info t1, Info t2) (Info rettype') loc
    _ -> typeError loc $
         "Operator section with invalid operator of type " ++ pretty ftype

checkExp (OpSectionRight op _ e _ _ loc) = do
  (op', il, ftype) <- lookupVar loc op
  (e', e_arg) <- checkArg e
  case ftype of
    Arrow as1 m1 t1 (Arrow as2 m2 t2 ret) -> do
      (t2' : t1' : rest, rettype) <-
        checkApply loc (Arrow as2 m2 t2 (Arrow as1 m1 t1 ret)) e_arg
      let rettype' = foldr (Arrow mempty Nothing .
                             removeShapeAnnotations . fromStruct) rettype rest
      return $ OpSectionRight op' (Info il) e' (Info t1', Info t2') (Info rettype') loc
    _ -> typeError loc $
         "Operator section with invalid operator of type " ++ pretty ftype

checkExp (DoLoop tparams mergepat mergeexp form loopbody loc) =
  sequentially (checkExp mergeexp) $ \mergeexp' _ -> do

  noTypeParamsPermitted tparams

  zeroOrderType (srclocOf mergeexp) "used as loop variable" (typeOf mergeexp')

  merge_t <- do
    merge_t <- expType mergeexp'
    return $ Ascribed $ vacuousShapeAnnotations $ merge_t `setAliases` mempty

  -- First we do a basic check of the loop body to figure out which of
  -- the merge parameters are being consumed.  For this, we first need
  -- to check the merge pattern, which requires the (initial) merge
  -- expression.
  --
  -- Play a little with occurences to ensure it does not look like
  -- none of the merge variables are being used.
  ((tparams', mergepat', form', loopbody'), bodyflow) <-
    case form of
      For i uboundexp -> do
        uboundexp' <- require anySignedType =<< checkExp uboundexp
        bound_t <- expType uboundexp'
        bindingIdent i bound_t $ \i' ->
          noUnique $ bindingPattern tparams mergepat merge_t $
          \tparams' mergepat' -> onlySelfAliasing $ tapOccurences $ do
            loopbody' <- checkExp loopbody
            return (tparams',
                    mergepat',
                    For i' uboundexp',
                    loopbody')

      ForIn xpat e -> do
        (arr_t, _) <- newArrayType (srclocOf e) "e" 1
        e' <- unifies arr_t =<< checkExp e
        t <- expType e'
        case t of
          _ | Just t' <- peelArray 1 t ->
                bindingPattern [] xpat (Ascribed $ vacuousShapeAnnotations t') $ \_ xpat' ->
                noUnique $ bindingPattern tparams mergepat merge_t $
                \tparams' mergepat' -> onlySelfAliasing $ tapOccurences $ do
                  loopbody' <- checkExp loopbody
                  return (tparams',
                          mergepat',
                          ForIn xpat' e',
                          loopbody')
            | otherwise ->
                typeError (srclocOf e) $
                "Iteratee of a for-in loop must be an array, but expression has type " ++ pretty t

      While cond ->
        noUnique $ bindingPattern tparams mergepat merge_t $ \tparams' mergepat' ->
        onlySelfAliasing $ tapOccurences $
        sequentially (unifies (Prim Bool) =<< checkExp cond) $ \cond' _ -> do
          loopbody' <- checkExp loopbody
          return (tparams',
                  mergepat',
                  While cond',
                  loopbody')

  mergepat'' <- do
    loop_t <- expType loopbody'
    convergePattern mergepat' (allConsumed bodyflow) loop_t (srclocOf loopbody')

  let consumeMerge (Id _ (Info pt) ploc) mt
        | unique pt = consume ploc $ aliases mt
      consumeMerge (TuplePattern pats _) t | Just ts <- isTupleRecord t =
        zipWithM_ consumeMerge pats ts
      consumeMerge (PatternParens pat _) t =
        consumeMerge pat t
      consumeMerge (PatternAscription pat _) t =
        consumeMerge pat t
      consumeMerge _ _ =
        return ()
  consumeMerge mergepat'' =<< expType mergeexp'
  return $ DoLoop tparams' mergepat'' mergeexp' form' loopbody' loc

  where
    convergePattern pat body_cons body_t body_loc = do
      let consumed_merge = S.map identName (patIdentSet pat) `S.intersection`
                           body_cons
          uniquePat (Wildcard (Info t) wloc) =
            Wildcard (Info $ t `setUniqueness` Nonunique) wloc
          uniquePat (PatternParens p ploc) =
            PatternParens (uniquePat p) ploc
          uniquePat (Id name (Info t) iloc)
            | name `S.member` consumed_merge =
                let t' = t `setUniqueness` Unique `setAliases` mempty
                in Id name (Info t') iloc
            | otherwise =
                let t' = case t of Record{} -> t
                                   _        -> t `setUniqueness` Nonunique
                in Id name (Info t') iloc
          uniquePat (TuplePattern pats ploc) =
            TuplePattern (map uniquePat pats) ploc
          uniquePat (RecordPattern fs ploc) =
            RecordPattern (map (fmap uniquePat) fs) ploc
          uniquePat (PatternAscription p t) =
            PatternAscription p t

          -- Make the pattern unique where needed.
          pat' = uniquePat pat

      -- Now check that the loop returned the right type.
      unify body_loc (toStruct body_t) $ toStruct $ patternType pat'
      body_t' <- normaliseType body_t
      unless (body_t' `subtypeOf` patternType pat') $
        throwError $ UnexpectedType body_loc
        (toStructural body_t')
        [toStructural $ patternType pat']

      -- Check that the new values of consumed merge parameters do not
      -- alias something bound outside the loop, AND that anything
      -- returned for a unique merge parameter does not alias anything
      -- else returned.
      bound_outside <- asks $ S.fromList . M.keys . scopeVtable
      let checkMergeReturn (Id pat_v (Info pat_t) _) t
            | unique pat_t,
              v:_ <- S.toList $ aliases t `S.intersection` bound_outside =
                lift $ typeError loc $ "Loop return value corresponding to merge parameter " ++
                pretty pat_v ++ " aliases " ++ pretty v ++ "."
            | otherwise = do
                (cons,obs) <- get
                unless (S.null $ aliases t `S.intersection` cons) $
                  lift $ typeError loc $ "Loop return value for merge parameter " ++
                  pretty pat_v ++ " aliases other consumed merge parameter."
                when (unique pat_t &&
                      not (S.null (aliases t `S.intersection` (cons<>obs)))) $
                  lift $ typeError loc $ "Loop return value for consuming merge parameter " ++
                  pretty pat_v ++ " aliases previously returned value." ++ show (aliases t, cons, obs)
                if unique pat_t
                  then put (cons<>aliases t, obs)
                  else put (cons, obs<>aliases t)
          checkMergeReturn (TuplePattern pats _) t | Just ts <- isTupleRecord t =
            zipWithM_ checkMergeReturn pats ts
          checkMergeReturn _ _ =
            return ()
      (pat_cons, _) <- execStateT (checkMergeReturn pat' body_t') (mempty, mempty)
      let body_cons' = body_cons <> pat_cons
      if body_cons' == body_cons && patternType pat' == patternType pat
        then return pat'
        else convergePattern pat' body_cons' body_t' body_loc

checkSOACArrayArg :: ExpBase NoInfo Name
                  -> TermTypeM (Exp, Arg)
checkSOACArrayArg e = do
  (e', (t, dflow, argloc)) <- checkArg e
  (arr_t, _) <- newArrayType argloc "e" 1
  unify (srclocOf e) arr_t (toStruct t)
  t' <- normaliseType t
  case peelArray 1 t' of
    Nothing -> typeError argloc "SOAC argument is not an array"
    Just rt -> return (e', (rt, dflow, argloc))

checkIdent :: IdentBase NoInfo Name -> TermTypeM Ident
checkIdent (Ident name _ loc) = do
  (QualName _ name', _, vt) <- lookupVar loc (qualName name)
  return $ Ident name' (Info vt) loc

checkDimIndex :: DimIndexBase NoInfo Name -> TermTypeM DimIndex
checkDimIndex (DimFix i) =
  DimFix <$> (unifies (Prim $ Signed Int32) =<< checkExp i)
checkDimIndex (DimSlice i j s) =
  DimSlice
  <$> maybe (return Nothing) (fmap Just . unifies (Prim $ Signed Int32) <=< checkExp) i
  <*> maybe (return Nothing) (fmap Just . unifies (Prim $ Signed Int32) <=< checkExp) j
  <*> maybe (return Nothing) (fmap Just . unifies (Prim $ Signed Int32) <=< checkExp) s

sequentially :: TermTypeM a -> (a -> Occurences -> TermTypeM b) -> TermTypeM b
sequentially m1 m2 = do
  (a, m1flow) <- collectOccurences m1
  (b, m2flow) <- collectOccurences $ m2 a m1flow
  occur $ m1flow `seqOccurences` m2flow
  return b

findFuncall :: UncheckedExp -> TermTypeM (QualName Name, [UncheckedExp])
findFuncall (Parens e _) =
  findFuncall e
findFuncall (Var fname _ _) =
  return (fname, [])
findFuncall (Apply f arg _ _ _) = do
  (fname, args) <- findFuncall f
  return (fname, args ++ [arg])
findFuncall e =
  typeError (srclocOf e) "Invalid function expression in application."

constructFuncall :: SrcLoc -> QualName VName -> [TypeBase () ()]
                 -> [Exp] -> [StructType] -> TypeBase dim Names
                 -> TermTypeM Exp
constructFuncall loc fname il args paramtypes rettype = do
  let rettype' = removeShapeAnnotations rettype
  return $ foldl (\f (arg,d,remnant) -> Apply f arg (Info d) (Info (remnant, rettype')) loc)
                 (Var fname (Info (il, paramtypes, rettype')) loc)
                 (zip3 args (map diet paramtypes) $ drop 1 $ tails paramtypes)


type Arg = (CompType, Occurences, SrcLoc)

argType :: Arg -> CompType
argType (t, _, _) = t

checkArg :: UncheckedExp -> TermTypeM (Exp, Arg)
checkArg arg = do
  (arg', dflow) <- collectOccurences $ checkExp arg
  arg_t <- expType arg'
  return (arg', (arg_t, dflow, srclocOf arg'))

checkApply :: SrcLoc -> CompType -> Arg
           -> TermTypeM ([StructType], CompType)
checkApply loc (Arrow as _ tp1 tp2) (argtype, dflow, argloc) = do
  unify loc (toStruct tp1) (toStruct argtype)
  let (paramtypes, rettype) = unfoldFunType tp2

  -- Perform substitutions of instantiated variables in the types.
  rettype' <- normaliseType rettype
  tp1' <- normaliseType tp1
  paramtypes' <- mapM normaliseType paramtypes

  occur [observation as loc]

  maybeCheckOccurences dflow
  occurs <- consumeArg argloc argtype (diet tp1')
  occur $ dflow `seqOccurences` occurs

  return (map (vacuousShapeAnnotations . toStruct) $ tp1' : paramtypes',
          returnType (toStruct rettype') [diet tp1'] [argtype])

checkApply loc tfun@TypeVar{} arg = do
  tv <- newTypeVar loc "b"
  unify loc (toStruct tfun) $ Arrow mempty Nothing (toStruct (argType arg)) tv
  substs <- gets constraintSubsts
  checkApply loc (applySubst substs tfun) arg

checkApply loc ftype arg =
  typeError loc $
  "Attempt to apply an expression of type " ++ pretty ftype ++
  " to an argument of type " ++ pretty (argType arg) ++ "."

checkFuncall :: SrcLoc -> CompType -> [Arg]
             -> TermTypeM ([StructType], CompType)
checkFuncall _ ftype [] = return ([], ftype)
checkFuncall loc ftype ((argtype, dflow, argloc) : args) =
  case ftype of
    Arrow as _ t1 t2 -> do
      unify loc (toStructural t1) (toStruct argtype)
      substs <- gets constraintSubsts
      let t1' = toStruct $ applySubst substs t1
          t2' = applySubst substs t2

      occur [observation as loc]
      maybeCheckOccurences dflow
      occurs <- consumeArg argloc argtype (diet t1')
      occur $ dflow `seqOccurences` occurs

      (ps, ret) <- checkFuncall loc t2' args
      return (vacuousShapeAnnotations t1' : ps, ret)

    _ -> typeError loc $
         "Attempt to apply an expression of type " ++ pretty ftype ++
         " to an argument of type " ++ pretty argtype ++ "."

consumeArg :: SrcLoc -> CompType -> Diet -> TermTypeM [Occurence]
consumeArg loc (Record ets) (RecordDiet ds) =
  concat . M.elems <$> traverse (uncurry $ consumeArg loc) (M.intersectionWith (,) ets ds)
consumeArg loc (Array _ _ Nonunique) Consume =
  typeError loc "Consuming parameter passed non-unique argument."
consumeArg loc at Consume = return [consumption (aliases at) loc]
consumeArg loc at _       = return [observation (aliases at) loc]

checkOneExp :: UncheckedExp -> TypeM Exp
checkOneExp e = fmap fst . runTermTypeM $ updateExpTypes =<< checkExp e

maybePermitRecursion :: VName -> [TypeParam] -> [Pattern] -> Maybe StructType
                     -> TermTypeM a -> TermTypeM a
maybePermitRecursion fname tparams params (Just rettype) m = do
  permit <- liftTypeM recursionPermitted
  if permit then
    let patternType' = toStruct . vacuousShapeAnnotations . patternType
        entry = BoundV tparams $
                foldr (Arrow () Nothing . patternType') rettype params `setAliases` mempty
        bindF scope = scope { scopeVtable = M.insert fname entry $ scopeVtable scope }
    in local bindF m
    else m
maybePermitRecursion _ _ _ Nothing m = m

checkFunDef :: (Name, Maybe UncheckedTypeExp,
                [UncheckedTypeParam], [UncheckedPattern],
                UncheckedExp, SrcLoc)
            -> TypeM (VName, [TypeParam], [Pattern], Maybe (TypeExp VName), StructType, Exp)
checkFunDef = fmap fst . runTermTypeM . checkFunDef'

checkFunDef' :: (Name, Maybe UncheckedTypeExp,
                 [UncheckedTypeParam], [UncheckedPattern],
                 UncheckedExp, SrcLoc)
             -> TermTypeM (VName, [TypeParam], [Pattern], Maybe (TypeExp VName), StructType, Exp)
checkFunDef' (fname, maybe_retdecl, tparams, params, body, loc) = noUnique $ do
  fname' <- checkName Term fname loc

  when (baseString fname' == "&&") $
    typeError loc "The && operator may not be redefined."

  when (baseString fname' == "||") $
    typeError loc "The || operator may not be redefined."

  then_substs <- get

  bindingPatternGroup tparams (zip params $ repeat NoneInferred) $ \tparams' params' -> do
    maybe_retdecl' <- traverse checkTypeExp maybe_retdecl

    body' <- maybePermitRecursion fname' tparams' params' (snd <$> maybe_retdecl') $
             checkFunBody body (snd <$> maybe_retdecl') (maybe loc srclocOf maybe_retdecl)

    -- We are now done inferring types.  Replace all inferred types in
    -- the body and parameters.
    body'' <- updateExpTypes body'
    params'' <- updateExpTypes params'

    body_t <- expType body''
    (maybe_retdecl'', rettype) <- case maybe_retdecl' of
      Just (retdecl', retdecl_type) -> do
        let rettype_structural = toStructural retdecl_type
        checkReturnAlias rettype_structural params'' body_t
        return (Just retdecl', retdecl_type)
      Nothing -> return (Nothing, vacuousShapeAnnotations $ toStruct body_t)

    now_substs <- get
    let new_substs = now_substs `M.difference` then_substs
    tparams'' <- closeOverTypes new_substs tparams' $
                 rettype : map patternStructType params''
    put $ then_substs `M.intersection` now_substs

    return (fname', tparams'', params'', maybe_retdecl'', rettype, body'')

  where -- | Check that unique return values do not alias a
        -- non-consumed parameter.
        checkReturnAlias rettp params' =
          foldM_ (checkReturnAlias' params') S.empty . returnAliasing rettp
        checkReturnAlias' params' seen (Unique, names)
          | any (`S.member` S.map snd seen) $ S.toList names =
            throwError $ UniqueReturnAliased fname loc
          | otherwise = do
            notAliasingParam params' names
            return $ seen `S.union` tag Unique names
        checkReturnAlias' _ seen (Nonunique, names)
          | any (`S.member` seen) $ S.toList $ tag Unique names =
            throwError $ UniqueReturnAliased fname loc
          | otherwise = return $ seen `S.union` tag Nonunique names

        notAliasingParam params' names =
          forM_ params' $ \p ->
          let consumedNonunique p' =
                not (unique $ unInfo $ identType p') && (identName p' `S.member` names)
          in case find consumedNonunique $ S.toList $ patIdentSet p of
               Just p' ->
                 throwError $ ReturnAliased fname (baseName $ identName p') loc
               Nothing ->
                 return ()

        tag u = S.map $ \name -> (u, name)

        returnAliasing (Record ets1) (Record ets2) =
          concat $ M.elems $ M.intersectionWith returnAliasing ets1 ets2
        returnAliasing expected got = [(uniqueness expected, aliases got)]

checkFunBody :: ExpBase NoInfo Name
             -> Maybe StructType
             -> SrcLoc
             -> TermTypeM Exp
checkFunBody body maybe_rettype _loc = do
  body' <- checkExp body

  -- Unify body return type with return annotation, if one exists.
  case maybe_rettype of
    Just rettype -> do
      let rettype_structural = toStructural rettype
      void $ unifies rettype_structural body'
    Nothing -> return ()

  return body'

-- | Find at all type variables in the given type that are covered by
-- the constraints, and produce type parameters that close over them.
-- Produce an error if the given list of type parameters is non-empty,
-- yet does not cover all type variables in the type.
closeOverTypes :: Constraints -> [TypeParam] -> [StructType] -> TermTypeM [TypeParam]
closeOverTypes substs tparams ts = do
  -- Check that there are not unconstrained type variables left,
  -- except for those closed over by the type variables.
  mapM_ constrained $ M.elems $ M.filterWithKey (\k _ -> k `S.notMember` visible) substs

  case tparams of
    [] -> fmap catMaybes $ mapM closeOver $ M.toList substs'
    _ -> do mapM_ checkClosedOver $ M.toList substs'
            return tparams
  where substs' = M.filterWithKey (\k _ -> k `S.member` visible) substs
        visible = mconcat (map typeVars ts)

        checkClosedOver (k, _v)
          | k `elem` map typeParamName tparams = return ()
          | otherwise =
              typeError noLoc $
              "Type variable " ++ pretty k ++ " not closed over by type parameters " ++
              intercalate ", " (map pretty tparams) ++ "."

        closeOver (k, NoConstraint (Just Unlifted) loc) = return $ Just $ TypeParamType k loc
        closeOver (k, NoConstraint _ loc) = return $ Just $ TypeParamLiftedType k loc
        closeOver (_, ParamType{}) = return Nothing
        closeOver (_, Constraint{}) = return Nothing
        closeOver (_, Overloaded ots loc) =
          typeError loc $
          "Type is ambiguous (could be one of " ++ intercalate ", " (map pretty ots) ++ ")."
        closeOver (_, Equality loc) =
          typeError loc "Type is ambiguous (must be equality type)."

        constrained (NoConstraint _ loc) = ambiguous loc
        constrained (Overloaded _ loc) = ambiguous loc
        constrained (Equality loc) = ambiguous loc
        constrained _ = return ()
        ambiguous loc = typeError loc "Type of expression is ambiguous."

-- | Checking an expression that is in function position, like the
-- functional argument to a map.
checkFunExp :: UncheckedExp -> [Arg] -> TermTypeM (Exp, TypeBase () ())
checkFunExp (Parens e loc) args = do
  (e', t) <- checkFunExp e args
  return (Parens e' loc, t)

checkFunExp (Lambda tparams params body maybe_ret NoInfo loc) args
  | length params == length args = do
      let params_with_ts = zip params $ map (Inferred . fromStruct . argType) args
      (maybe_ret', tparams', params', body') <-
        noUnique $ bindingPatternGroup tparams params_with_ts $ \tparams' params' -> do
        maybe_ret' <- traverse checkTypeDecl maybe_ret
        body' <- checkFunBody body (unInfo . expandedType <$> maybe_ret') loc
        return (maybe_ret', tparams', params', body')

      ret' <- case maybe_ret' of
                Nothing -> vacuousShapeAnnotations . (`setAliases` ()) <$> expType body'
                Just (TypeDecl _ (Info ret)) -> return ret
      let lamt = foldr (Arrow () Nothing . toStruct . patternType)
                 (removeShapeAnnotations ret') params' `setAliases` mempty
      void $ checkFuncall loc lamt args
      return (Lambda tparams' params' body' maybe_ret' (Info $ toStruct ret') loc,
              removeShapeAnnotations $ toStruct ret')
  | otherwise = typeError loc $ "Anonymous function defined with " ++
                show (length params) ++ " parameters, but expected to take " ++
                show (length args) ++ " arguments."

checkFunExp (OpSection op NoInfo NoInfo NoInfo NoInfo loc) args
  | [x_arg,y_arg] <- args = do
  (op', il, ftype) <- lookupVar loc op
  (paramtypes', rettype') <- checkFuncall loc ftype [x_arg,y_arg]

  case paramtypes' of
    [x_t, y_t] ->
      return (OpSection op' (Info il)
              (Info x_t) (Info y_t)
              (Info $ removeShapeAnnotations rettype') loc,
              removeShapeAnnotations rettype' `setAliases` mempty)
    _ ->
      fail "Internal type checker error: BinOpFun got bad parameter type."

  | otherwise =
      throwError $ ParameterMismatch (Just op) loc (Left 2) $
      map (toStructural . argType) args

checkFunExp (OpSectionLeft binop NoInfo x _ _ loc) args
  | [arg] <- args = do
      (x', binop', il, xt, yt, ret) <- checkCurryBinOp id binop x loc arg
      return (OpSectionLeft binop' (Info il)
              x' (Info xt, Info yt) (Info ret) loc,
              ret `setAliases` mempty)
  | otherwise =
      throwError $ ParameterMismatch (Just binop) loc (Left 1) $
      map (toStructural . argType) args

checkFunExp (OpSectionRight binop NoInfo x _ _ loc) args
  | [arg] <- args = do
      (x', binop', il, xt, yt, ret) <- checkCurryBinOp (uncurry $ flip (,)) binop x loc arg
      return (OpSectionRight binop' (Info il)
               x' (Info xt, Info yt) (Info ret) loc,
              ret `setAliases` mempty)
  | otherwise =
      throwError $ ParameterMismatch (Just binop) loc (Left 1) $
      map (toStructural . argType) args

checkFunExp e args = do
  (fname, curryargexps) <- findFuncall e
  (curryargexps', curryargs) <- unzip <$> mapM checkArg curryargexps
  let all_args = curryargs ++ args
  (fname', instance_list, ftype) <- lookupVar loc fname

  (paramtypes, rettype) <- checkFuncall loc ftype all_args

  case find (unique . snd) $ zip curryargexps paramtypes of
    Just (arg, _) -> throwError $ CurriedConsumption fname $ srclocOf arg
    _             -> return ()

  let rettype' = removeShapeAnnotations rettype
  e' <- constructFuncall loc fname' instance_list curryargexps' paramtypes rettype'
  return (e', rettype' `setAliases` mempty)
  where loc = srclocOf e

checkCurryBinOp :: ((Arg,Arg) -> (Arg,Arg))
                -> QualName Name -> ExpBase NoInfo Name -> SrcLoc -> Arg
                -> TermTypeM (Exp, QualName VName, [TypeBase () ()],
                              StructType, StructType, CompType)
checkCurryBinOp arg_ordering binop x loc y_arg = do
  (x', x_arg) <- checkArg x
  let (first_arg, second_arg) = arg_ordering (x_arg, y_arg)
  (binop', il, fun) <- lookupVar loc binop
  ([xt, yt], rettype) <- checkFuncall loc fun [first_arg,second_arg]
  return (x', binop', il, xt, yt, removeShapeAnnotations rettype)

--- Consumption

occur :: Occurences -> TermTypeM ()
occur = tell

-- | Proclaim that we have made read-only use of the given variable.
observe :: Ident -> TermTypeM ()
observe (Ident nm (Info t) loc) =
  let als = nm `S.insert` aliases t
  in occur [observation als loc]

-- | Proclaim that we have written to the given variable.
consume :: SrcLoc -> Names -> TermTypeM ()
consume loc als = occur [consumption als loc]

-- | Proclaim that we have written to the given variable, and mark
-- accesses to it and all of its aliases as invalid inside the given
-- computation.
consuming :: Ident -> TermTypeM a -> TermTypeM a
consuming (Ident name (Info t) loc) m = do
  consume loc $ name `S.insert` aliases t
  local consume' m
  where consume' scope =
          scope { scopeVtable = M.insert name (WasConsumed loc) $ scopeVtable scope }

collectOccurences :: TermTypeM a -> TermTypeM (a, Occurences)
collectOccurences m = pass $ do
  (x, dataflow) <- listen m
  return ((x, dataflow), const mempty)

tapOccurences :: TermTypeM a -> TermTypeM (a, Occurences)
tapOccurences = listen

maybeCheckOccurences :: Occurences -> TermTypeM ()
maybeCheckOccurences = badOnLeft . checkOccurences

checkIfUsed :: Occurences -> Ident -> TermTypeM ()
checkIfUsed occs v
  | not $ identName v `S.member` allOccuring occs,
    not $ "_" `isPrefixOf` pretty (identName v) =
      warn (srclocOf v) $ "Unused variable '"++pretty (baseName $ identName v)++"'."
  | otherwise =
      return ()

alternative :: TermTypeM a -> TermTypeM b -> TermTypeM (a,b)
alternative m1 m2 = pass $ do
  (x, occurs1) <- listen m1
  (y, occurs2) <- listen m2
  maybeCheckOccurences occurs1
  maybeCheckOccurences occurs2
  let usage = occurs1 `altOccurences` occurs2
  return ((x, y), const usage)

-- | Make all bindings nonunique.
noUnique :: TermTypeM a -> TermTypeM a
noUnique = local (\scope -> scope { scopeVtable = M.map set $ scopeVtable scope})
  where set (BoundV tparams t)      = BoundV tparams $ t `setUniqueness` Nonunique
        set (OverloadedF ts pts rt) = OverloadedF ts pts rt
        set EqualityF               = EqualityF
        set OpaqueF                 = OpaqueF
        set (WasConsumed loc)       = WasConsumed loc

onlySelfAliasing :: TermTypeM a -> TermTypeM a
onlySelfAliasing = local (\scope -> scope { scopeVtable = M.mapWithKey set $ scopeVtable scope})
  where set k (BoundV tparams t)      = BoundV tparams $ t `addAliases` S.intersection (S.singleton k)
        set _ (OverloadedF ts pts rt) = OverloadedF ts pts rt
        set _ EqualityF               = EqualityF
        set _ OpaqueF                 = OpaqueF
        set _ (WasConsumed loc)       = WasConsumed loc

--- Unification.

-- | Unifies two types.
unify :: SrcLoc -> TypeBase () () -> TypeBase () () -> TermTypeM ()
unify loc orig_t1 orig_t2 = do
  orig_t1' <- normaliseType orig_t1
  orig_t2' <- normaliseType orig_t2
  breadCrumb (MatchingTypes orig_t1' orig_t2') $ subunify orig_t1 orig_t2
  where
    subunify t1 t2 = do
      constraints <- get

      let isRigid' v = isRigid v constraints
          substs = constraintSubsts constraints
          t1' = applySubst substs t1
          t2' = applySubst substs t2

          failure =
            typeError loc $ "Couldn't match type `" ++
            pretty t1' ++ "' with type `" ++ pretty t2' ++ "'."

      case (t1', t2') of
        _ | t1' == t2' -> return ()

        (Record fs,
         Record arg_fs)
          | M.keys fs == M.keys arg_fs ->
              mapM_ (uncurry subunify) $
              M.intersectionWith (,) fs arg_fs

        (TypeVar (TypeName _ tn) targs,
         TypeVar (TypeName _ arg_tn) arg_targs)
          | tn == arg_tn, length targs == length arg_targs ->
              zipWithM_ unifyTypeArg targs arg_targs

        (TypeVar (TypeName [] v1) [],
         TypeVar (TypeName [] v2) []) ->
          case (isRigid' v1, isRigid' v2) of
            (True, True) -> failure
            (True, False) -> linkVarToType loc v2 t1'
            (False, True) -> linkVarToType loc v1 t2'
            (False, False) -> linkVarToType loc v1 t2'

        (TypeVar (TypeName [] v1) [], _)
          | not $ isRigid' v1 ->
              linkVarToType loc v1 t2'
        (_, TypeVar (TypeName [] v2) [])
          | not $ isRigid' v2 ->
              linkVarToType loc v2 t1'

        (Arrow _ _ a1 b1,
         Arrow _ _ a2 b2) -> do
          subunify a1 a2
          subunify b1 b2

        (Array{}, Array{})
          | Just t1'' <- peelArray 1 t1',
            Just t2'' <- peelArray 1 t2' ->
              subunify t1'' t2''

        (_, _) -> failure

      where unifyTypeArg TypeArgDim{} TypeArgDim{} = return ()
            unifyTypeArg (TypeArgType t _) (TypeArgType arg_t _) =
              subunify t arg_t
            unifyTypeArg _ _ = typeError loc
              "Cannot unify a type argument with a dimension argument (or vice versa)."

linkVarToType :: SrcLoc -> VName -> TypeBase () () -> TermTypeM ()
linkVarToType loc vn tp = do
  constraints <- get
  if vn `S.member` typeVars tp
    then typeError loc $ "Occurs check: cannot instantiate " ++
         pretty vn ++ " with " ++ pretty tp'
    else do modify $ M.insert vn $ Constraint tp' loc
            case M.lookup vn constraints of
              Just (NoConstraint (Just Unlifted) unlift_loc) ->
                zeroOrderType loc ("used at " ++ locStr unlift_loc) tp'
              Just (Equality _) ->
                equalityType loc tp'
              Just (Overloaded ts old_loc)
                | tp `notElem` map Prim ts ->
                    case tp' of
                      TypeVar (TypeName [] v) []
                        | not $ isRigid v constraints -> linkVarToTypes loc v ts
                      _ ->
                        typeError loc $ "Cannot unify \"" ++ pretty vn ++ "\" with type \"" ++
                        pretty tp ++ "\" (must be one of " ++ intercalate ", " (map pretty ts) ++
                        " due to use at " ++ locStr old_loc ++ ")."
              _ -> return ()
            modify $ M.map $ applySubstInConstraint vn tp'
  where tp' = tp `setUniqueness` Nonunique

mustBeOneOf :: [PrimType] -> SrcLoc -> TypeBase () () -> TermTypeM ()
mustBeOneOf ts loc t = do
  constraints <- get
  let substs = constraintSubsts constraints
      t' = applySubst substs t
      isRigid' v = isRigid v constraints

  case t' of
    TypeVar (TypeName [] v) []
      | not $ isRigid' v -> linkVarToTypes loc v ts

    Prim pt | pt `elem` ts -> return ()

    _ -> failure

  where failure = typeError loc $ "Cannot unify type \"" ++ pretty t ++
                  "\" with any of " ++ intercalate "," (map pretty ts) ++ "."

linkVarToTypes :: SrcLoc -> VName -> [PrimType] -> TermTypeM ()
linkVarToTypes loc vn ts = modify $ M.insert vn $ Overloaded ts loc

equalityType :: (ArrayDim dim, Pretty (ShapeDecl dim), Monoid as) =>
                SrcLoc -> TypeBase dim as -> TermTypeM ()
equalityType loc t = do
  unless (orderZero t) $
    typeError loc $
    "Type \"" ++ pretty t ++ "\" does not support equality."
  mapM_ mustBeEquality $ typeVars t
  where mustBeEquality vn = do
          constraints <- get
          case M.lookup vn constraints of
            Just (Constraint (TypeVar (TypeName [] vn') []) _) ->
              mustBeEquality vn'
            Just (Constraint vn_t _)
              | not $ orderZero vn_t ->
                  typeError loc $ "Type \"" ++ pretty t ++
                  "\" does not support equality."
              | otherwise -> return ()
            Just (NoConstraint _ _) ->
              modify $ M.insert vn (Equality loc)
            Just (Overloaded _ _) ->
              return () -- All primtypes support equality.
            _ ->
              typeError loc $ "Type " ++ pretty vn ++
              " does not support equality."

zeroOrderType :: (ArrayDim dim, Pretty (ShapeDecl dim), Monoid as) =>
                 SrcLoc -> String -> TypeBase dim as -> TermTypeM ()
zeroOrderType loc desc t = do
  unless (orderZero t) $
    typeError loc $ "Type " ++ desc ++
    " must not be functional, but is " ++ pretty t ++ "."
  mapM_ mustBeZeroOrder . S.toList . typeVars $ t
  where mustBeZeroOrder vn = do
          constraints <- get
          case M.lookup vn constraints of
            Just (Constraint vn_t old_loc)
              | not $ orderZero t ->
                typeError loc $ "Type " ++ desc ++
                " must be non-function, but inferred to be " ++
                pretty vn_t ++ " at " ++ locStr old_loc ++ "."
            Just (NoConstraint Nothing _) ->
              modify $ M.insert vn (NoConstraint (Just Unlifted) loc)
            Just (NoConstraint (Just Lifted) old_loc) ->
              typeError loc $ "Type " ++ desc ++
              " must be non-function, but inferred functional at "
              ++ locStr old_loc ++ "."
            Just (ParamType Lifted ploc) ->
              typeError loc $ "Type " ++ desc ++
              " must be non-function, but type parameter " ++ pretty vn ++ " at " ++
              locStr ploc ++ " may be a function."
            _ -> return ()

arrayOfM :: (ArrayDim dim, Pretty (ShapeDecl dim), Monoid as) =>
            SrcLoc
         -> TypeBase dim as -> ShapeDecl dim -> Uniqueness
         -> TermTypeM (TypeBase dim as)
arrayOfM loc t shape u = do
  zeroOrderType loc "used in array" t
  maybe nope return $ arrayOf t shape u
  where nope = typeError loc $
               "Cannot form an array with elements of type " ++ pretty t

-- | Perform substitutions of instantiated variables on the type
-- annotations (including the instance lists) of an expression, or
-- something else.
updateExpTypes :: (ASTMappable e, Show e) => e -> TermTypeM e
updateExpTypes e = do
  substs <- gets constraintSubsts
  let tv = ASTMapper { mapOnExp         = astMap tv
                     , mapOnName        = pure
                     , mapOnQualName    = pure
                     , mapOnType        = pure . applySubst substs
                     , mapOnCompType    = pure . applySubst substs
                     , mapOnStructType  = pure . applySubst substs
                     , mapOnPatternType = pure . applySubst substs
                     }
  astMap tv e
