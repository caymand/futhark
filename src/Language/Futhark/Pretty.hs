{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE FlexibleInstances, FlexibleContexts #-}
-- | Futhark prettyprinter.  This module defines 'Pretty' instances for the
-- AST defined in "Language.Futhark.Syntax", but also a number of
-- convenience functions if you don't want to use the interface from
-- 'Pretty'.
module Language.Futhark.Pretty
  ( ppType
  , ppValue
  , ppUnOp
  , ppBinOp
  , ppExp
  , ppLambda
  , ppTupId
  , prettyPrint
  )
  where

import Data.Array
import Data.Hashable
import qualified Data.HashSet as HS

import Text.PrettyPrint.Mainland

import Language.Futhark.Syntax
import Language.Futhark.Attributes

-- | The document @'apply' ds@ separates @ds@ with commas and encloses them with
-- parentheses.
apply :: [Doc] -> Doc
apply = encloseSep lparen rparen comma . map align

commastack :: [Doc] -> Doc
commastack = align . stack . punctuate comma

aliasComment :: (Eq vn, Hashable vn, Pretty vn, TypeBox ty) => TupIdentBase ty vn -> Doc -> Doc
aliasComment pat d = case aliasComment' pat of
                       []   -> d
                       l:ls -> foldl (</>) l ls </> d
  where aliasComment' (Wildcard {}) = []
        aliasComment' (TupId pats _) = concatMap aliasComment' pats
        aliasComment' (Id ident) =
          case maybe [] (clean . HS.toList . aliases)
                 $ unboxType $ identType ident of
            [] -> []
            als -> [oneline $
                    text "// " <> ppr ident <> text " aliases " <>
                    commasep (map ppr als)]
          where clean = filter (/= identName ident)
                oneline s = text $ displayS (renderCompact s) ""

instance Pretty Value where
  ppr (BasicVal bv) = ppr bv
  ppr (TupVal vs)
    | any (not . basicType . valueType) vs =
      braces $ commastack $ map ppr vs
    | otherwise =
      braces $ commasep $ map ppr vs
  ppr v@(ArrayVal a t)
    | Just s <- arrayString v = text $ show s
    | [] <- elems a = text "empty" <> parens (ppr t)
    | Array {} <- t = brackets $ commastack $ map ppr $ elems a
    | otherwise     = brackets $ commasep $ map ppr $ elems a

instance Pretty Uniqueness where
  ppr Unique    = star
  ppr Nonunique = empty

instance (Eq vn, Hashable vn, Pretty vn) =>
         Pretty (TupleArrayElemTypeBase ShapeDecl as vn) where
  ppr (BasicArrayElem bt _) = ppr bt
  ppr (ArrayArrayElem at)   = ppr at
  ppr (TupleArrayElem ts)   = braces $ commasep $ map ppr ts

instance (Eq vn, Hashable vn, Pretty vn) =>
         Pretty (TupleArrayElemTypeBase Rank as vn) where
  ppr (BasicArrayElem bt _) = ppr bt
  ppr (ArrayArrayElem at)   = ppr at
  ppr (TupleArrayElem ts)   = braces $ commasep $ map ppr ts

instance (Eq vn, Hashable vn, Pretty vn) =>
         Pretty (ArrayTypeBase ShapeDecl as vn) where
  ppr (BasicArray et (ShapeDecl ds) u _) =
    ppr u <> foldl f (ppr et) ds
    where f s AnyDim       = brackets s
          f s (VarDim v)   = brackets $ s <> comma <> ppr v
          f s (KnownDim v) = brackets $ s <> comma <> text "!" <> ppr v
          f s (ConstDim n) = brackets $ s <> comma <> ppr n

  ppr (TupleArray et (ShapeDecl ds) u) =
    ppr u <> foldl f (braces $ commasep $ map ppr et) ds
    where f s AnyDim       = brackets s
          f s (VarDim v)   = brackets $ s <> comma <> ppr v
          f s (KnownDim v) = brackets $ s <> comma <> text "!" <> ppr v
          f s (ConstDim n) = brackets $ s <> comma <> ppr n

instance (Eq vn, Hashable vn, Pretty vn) => Pretty (ArrayTypeBase Rank as vn) where
  ppr (BasicArray et (Rank n) u _) =
    ppr u <> foldl (.) id (replicate n brackets) (ppr et)
  ppr (TupleArray ts (Rank n) u) =
    ppr u <> foldl (.) id (replicate n brackets)
    (braces $ commasep $ map ppr ts)

instance (Eq vn, Hashable vn, Pretty vn) => Pretty (TypeBase ShapeDecl as vn) where
  ppr (Basic et) = ppr et
  ppr (Array at) = ppr at
  ppr (Tuple ts) = braces $ commasep $ map ppr ts

instance (Eq vn, Hashable vn, Pretty vn) => Pretty (TypeBase Rank as vn) where
  ppr (Basic et) = ppr et
  ppr (Array at) = ppr at
  ppr (Tuple ts) = braces $ commasep $ map ppr ts

instance (Eq vn, Hashable vn, Pretty vn) => Pretty (IdentBase ty vn) where
  ppr = ppr . identName

instance Pretty UnOp where
  ppr Not = text "not"
  ppr Negate = text "-"

instance Pretty BinOp where
  ppr Plus = text "+"
  ppr Minus = text "-"
  ppr Pow = text "pow"
  ppr Times = text "*"
  ppr Divide = text "/"
  ppr Mod = text "%"
  ppr ShiftR = text ">>"
  ppr ShiftL = text "<<"
  ppr Band = text "&"
  ppr Xor = text "^"
  ppr Bor = text "|"
  ppr LogAnd = text "&&"
  ppr LogOr = text "||"
  ppr Equal = text "=="
  ppr Less = text "<"
  ppr Leq = text "<="
  ppr Greater = text "<="
  ppr Geq = text "<="

hasArrayLit :: ExpBase ty vn -> Bool
hasArrayLit (ArrayLit {}) = True
hasArrayLit (TupLit es2 _) = any hasArrayLit es2
hasArrayLit (Literal val _) = hasArrayVal val
hasArrayLit _ = False

hasArrayVal :: Value -> Bool
hasArrayVal (ArrayVal {}) = True
hasArrayVal (TupVal vs) = any hasArrayVal vs
hasArrayVal _ = False

instance (Eq vn, Hashable vn, Pretty vn, TypeBox ty) => Pretty (ExpBase ty vn) where
  ppr = pprPrec (-1)
  pprPrec _ (Var v) = ppr v
  pprPrec _ (Literal v _) = ppr v
  pprPrec _ (TupLit es _)
    | any hasArrayLit es = braces $ commastack $ map ppr es
    | otherwise          = braces $ commasep $ map ppr es
  pprPrec _ (ArrayLit es rt _) =
    case unboxType rt of
      Just (Array {}) -> brackets $ commastack $ map ppr es
      _               -> brackets $ commasep $ map ppr es
  pprPrec p (BinOp bop x y _ _) = prettyBinOp p bop x y
  pprPrec _ (UnOp Not e _) = text "not" <+> pprPrec 9 e
  pprPrec _ (UnOp Negate e _) = text "-" <> pprPrec 9 e
  pprPrec _ (If c t f _ _) = text "if" <+> ppr c </>
                             text "then" <+> align (ppr t) </>
                             text "else" <+> align (ppr f)
  pprPrec _ (Apply fname args _ _) = text (nameToString fname) <>
                                     apply (map (align . ppr . fst) args)
  pprPrec p (LetPat pat e body _) =
    aliasComment pat $ mparens $ align $
    text "let" <+> align (ppr pat) <+>
    (if linebreak
     then equals </> indent 2 (ppr e)
     else equals <+> align (ppr e)) <+> text "in" </>
    ppr body
    where mparens = if p == -1 then id else parens
          linebreak = case e of
                        Map {} -> True
                        Reduce {} -> True
                        Filter {} -> True
                        Redomap {} -> True
                        Scan {} -> True
                        DoLoop {} -> True
                        LetPat {} -> True
                        LetWith {} -> True
                        Literal (ArrayVal {}) _ -> False
                        If {} -> True
                        ArrayLit {} -> False
                        _ -> hasArrayLit e
  pprPrec _ (LetWith dest src idxs ve body _)
    | dest == src =
      text "let" <+> ppr dest <+> list (map ppr idxs) <+>
      equals <+> align (ppr ve) <+>
      text "in" </> ppr body
    | otherwise =
      text "let" <+> ppr dest <+> equals <+> ppr src <+>
      text "with" <+> brackets (commasep (map ppr idxs)) <+>
      text "<-" <+> align (ppr ve) <+>
      text "in" </> ppr body
  pprPrec _ (Index v idxs _) =
    ppr v <> brackets (commasep (map ppr idxs))
  pprPrec _ (Iota e _) = text "iota" <> parens (ppr e)
  pprPrec _ (Size i e _) =
    text "size" <> apply [text $ show i, ppr e]
  pprPrec _ (Replicate ne ve _) =
    text "replicate" <> apply [ppr ne, align (ppr ve)]
  pprPrec _ (Reshape shape e _) =
    text "reshape" <> apply [apply (map ppr shape), ppr e]
  pprPrec _ (Rearrange perm e _) =
    text "rearrange" <> apply [apply (map ppr perm), ppr e]
  pprPrec _ (Transpose 0 1 e _) =
    text "transpose" <> apply [ppr e]
  pprPrec _ (Transpose k n e _) =
    text "transpose" <> apply [text $ show k,
                               text $ show n,
                               ppr e]
  pprPrec _ (Map lam a _) = ppSOAC "map" [lam] [a]
  pprPrec _ (ConcatMap lam a as _) = ppSOAC "concatMap" [lam] $ a : as
  pprPrec _ (Reduce lam e a _) = ppSOAC "reduce" [lam] [e, a]
  pprPrec _ (Redomap redlam maplam e a _) =
    ppSOAC "redomap" [redlam, maplam] [e, a]
  pprPrec _ (Stream chunk i acc arr lam _) =
    let args = [ppr chunk, ppr i, ppr acc, ppr arr]
    in  text "stream" <>  parens ( commasep args <> comma </>
                                   ppList [lam] )
  pprPrec _ (Scan lam e a _) = ppSOAC "scan" [lam] [e, a]
  pprPrec _ (Filter lam a _) = ppSOAC "filter" [lam] [a]
  pprPrec _ (Partition lams a _) = ppSOAC "partition" lams [a]
  pprPrec _ (Zip es _) = text "zip" <> apply (map (ppr . fst) es)
  pprPrec _ (Unzip e _ _) = text "unzip" <> parens (ppr e)
  pprPrec _ (Split e a _) =
    text "split" <> apply [ppr e, ppr a]
  pprPrec _ (Concat x y _) =
    text "concat" <> apply [ppr x, ppr y]
  pprPrec _ (Copy e _) = text "copy" <> parens (ppr e)
  pprPrec _ (DoLoop pat initexp form loopbody letbody _) =
    aliasComment pat $
    text "loop" <+> parens (ppr pat <+> equals <+> ppr initexp) <+> equals <+>
    (case form of
       ForLoop i bound ->
         text "for" <+> ppr i <+> text "<" <+> align (ppr bound)
       WhileLoop cond ->
         text "while" <+> ppr cond) <+>
    text "do" </>
    indent 2 (ppr loopbody) <+> text "in" </>
    ppr letbody

instance (Eq vn, Hashable vn, Pretty vn) => Pretty (TupIdentBase ty vn) where
  ppr (Id ident)     = ppr ident
  ppr (TupId pats _) = braces $ commasep $ map ppr pats
  ppr (Wildcard _ _) = text "_"

instance (Eq vn, Hashable vn, Pretty vn, TypeBox ty) => Pretty (LambdaBase ty vn) where
  ppr (CurryFun fname [] _ _) = text $ nameToString fname
  ppr (CurryFun fname curryargs _ _) =
    text (nameToString fname) <+> apply (map ppr curryargs)
  ppr (AnonymFun params body rettype _) =
    text "fn" <+> ppr rettype <+>
    apply (map ppParam params) <+>
    text "=>" </> indent 2 (ppr body)
  ppr (UnOpFun unop _ _) =
    ppr unop
  ppr (BinOpFun binop _ _) =
    ppr binop
  ppr (CurryBinOpLeft binop x _ _) =
    ppr x <+> ppr binop
  ppr (CurryBinOpRight binop x _ _) =
    ppr binop <+> ppr x

instance (Eq vn, Hashable vn, Pretty vn, TypeBox ty) => Pretty (ProgBase ty vn) where
  ppr = stack . punctuate line . map ppFun . progFunctions
    where ppFun (name, rettype, args, body, _) =
            text "fun" <+> ppr rettype <+>
            text (nameToString name) <//>
            apply (map ppParam args) <+>
            equals </> indent 2 (ppr body)

ppParam :: (Eq vn, Hashable vn, Pretty (ty vn), Pretty vn) => IdentBase ty vn -> Doc
ppParam param = ppr (identType param) <+> ppr param

prettyBinOp :: (Eq vn, Hashable vn, Pretty vn, TypeBox ty) =>
               Int -> BinOp -> ExpBase ty vn -> ExpBase ty vn -> Doc
prettyBinOp p bop x y = parensIf (p > precedence bop) $
                        pprPrec (precedence bop) x <+/>
                        text (ppBinOp bop) <+>
                        pprPrec (rprecedence bop) y
  where precedence LogAnd = 0
        precedence LogOr = 0
        precedence Band = 1
        precedence Bor = 1
        precedence Xor = 1
        precedence Equal = 2
        precedence Less = 2
        precedence Leq = 2
        precedence Greater = 2
        precedence Geq = 2
        precedence ShiftL = 3
        precedence ShiftR = 3
        precedence Plus = 4
        precedence Minus = 4
        precedence Times = 5
        precedence Divide = 5
        precedence Mod = 5
        precedence Pow = 6
        rprecedence Minus = 10
        rprecedence Divide = 10
        rprecedence op = precedence op

ppSOAC :: (Eq vn, Hashable vn, Pretty vn, TypeBox ty, Pretty fn) =>
          String -> [fn] -> [ExpBase ty vn] -> Doc
ppSOAC name funs es =
  text name <> parens (ppList funs </>
                       commasep (map ppr es))

ppList :: (Pretty a) => [a] -> Doc
ppList as = case map ppr as of
              []     -> empty
              a':as' -> foldl (</>) (a' <> comma) $ map (<> comma) as'

render80 :: Pretty a => a -> String
render80 = pretty 80 . ppr

-- | Prettyprint a value, wrapped to 80 characters.
ppValue :: Value -> String
ppValue = render80

-- | Prettyprint a type, wrapped to 80 characters.
ppType :: Pretty (TypeBase shape as vn) => TypeBase shape as vn -> String
ppType = render80

-- | Prettyprint a unary operator, wrapped to 80 characters.
ppUnOp :: UnOp -> String
ppUnOp = render80

-- | Prettyprint a binary operator, wrapped to 80 characters.
ppBinOp :: BinOp -> String
ppBinOp = render80

-- | Prettyprint an expression, wrapped to 80 characters.
ppExp :: (Eq vn, Hashable vn, Pretty vn, TypeBox ty) => ExpBase ty vn -> String
ppExp = render80

-- | Prettyprint a lambda, wrapped to 80 characters.
ppLambda :: (Eq vn, Hashable vn, Pretty vn, TypeBox ty) => LambdaBase ty vn -> String
ppLambda = render80

-- | Prettyprint a pattern, wrapped to 80 characters.
ppTupId :: (Eq vn, Hashable vn, Pretty vn, TypeBox ty) => TupIdentBase ty vn -> String
ppTupId = render80

-- | Prettyprint an entire Futhark program, wrapped to 80 characters.
prettyPrint :: (Eq vn, Hashable vn, Pretty vn, TypeBox ty) => ProgBase ty vn -> String
prettyPrint = render80
