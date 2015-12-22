{-# LANGUAGE TypeFamilies #-}
module Futhark.Pass.ExtractKernels.ISRWIM
       ( iswim
       , irwim)
       where

import Control.Arrow (first)
import Control.Monad.State
import Data.Monoid

import Prelude

import Futhark.MonadFreshNames
import Futhark.Representation.SOACS
import Futhark.Tools

iswim :: (MonadBinder m, Lore m ~ SOACS) =>
         Pattern
      -> Certificates
      -> SubExp
      -> Lambda
      -> [(SubExp, VName)]
      -> Maybe (m ())
iswim res_pat cs w scan_fun scan_input
  | Body () [bnd] res <- lambdaBody scan_fun, -- Body has a single binding
    map Var (patternNames $ bindingPattern bnd) == res, -- Returned verbatim
    Op (Map map_cs map_w map_fun map_arrs) <- bindingExp bnd,
    map paramName (lambdaParams scan_fun) == map_arrs = Just $ do
      let (accs, arrs) = unzip scan_input
      arrs' <- forM arrs $ \arr -> do
                 t <- lookupType arr
                 let perm = [1,0] ++ [2..arrayRank t-1]
                 letExp (baseString arr) $ PrimOp $ Rearrange [] perm arr
      accs' <- mapM (letExp "acc" . PrimOp . SubExp) accs

      let map_arrs' = accs' ++ arrs'
          (scan_acc_params, scan_elem_params) =
            splitAt (length arrs) $ lambdaParams scan_fun
          map_params = map removeParamOuterDim scan_acc_params ++
                       map (setParamOuterDimTo w) scan_elem_params
          map_rettype = map (setOuterDimTo w) $ lambdaReturnType scan_fun
          map_fun' = Lambda (lambdaIndex map_fun) map_params map_body map_rettype

          scan_params = lambdaParams map_fun
          scan_body = lambdaBody map_fun
          scan_rettype = lambdaReturnType map_fun
          scan_fun' = Lambda (lambdaIndex scan_fun) scan_params scan_body scan_rettype
          scan_input' = map (first Var) $
                        uncurry zip $ splitAt (length arrs') $ map paramName map_params

          map_body = mkBody [Let (setPatternOuterDimTo w $ bindingPattern bnd) () $
                             Op $ Scan cs w scan_fun' scan_input']
                            res

      res_pat' <- liftM (basicPattern' []) $
                  mapM (newIdent' (<>"_transposed") . transposeIdentType) $
                  patternValueIdents res_pat

      addBinding $ Let res_pat' () $ Op $ Map map_cs map_w map_fun' map_arrs'

      forM_ (zip (patternValueIdents res_pat)
                 (patternValueIdents res_pat')) $ \(to, from) -> do
        let perm = [1,0] ++ [2..arrayRank (identType from)-1]
        addBinding $ Let (basicPattern' [] [to]) () $
                     PrimOp $ Rearrange [] perm $ identName from
  | otherwise = Nothing

irwim :: (MonadBinder m, Lore m ~ SOACS) =>
         Pattern
      -> Certificates
      -> SubExp
      -> Lambda
      -> [(SubExp, VName)]
      -> Maybe (m ())
irwim res_pat cs w red_fun red_input
  | Body () [bnd] res <- lambdaBody red_fun, -- Body has a single binding
    map Var (patternNames $ bindingPattern bnd) == res, -- Returned verbatim
    Op (Map map_cs map_w map_fun map_arrs) <- bindingExp bnd,
    map paramName (lambdaParams red_fun) == map_arrs = Just $ do
      let (accs, arrs) = unzip red_input
      arrs' <- forM arrs $ \arr -> do
                 t <- lookupType arr
                 let perm = [1,0] ++ [2..arrayRank t-1]
                 letExp (baseString arr) $ PrimOp $ Rearrange [] perm arr
      accs' <- mapM (letExp "acc" . PrimOp . SubExp) accs

      let map_arrs' = accs' ++ arrs'
          (red_acc_params, red_elem_params) =
            splitAt (length arrs) $ lambdaParams red_fun
          map_params = map removeParamOuterDim red_acc_params ++
                       map (setParamOuterDimTo w) red_elem_params
          map_rettype = map rowType $ lambdaReturnType red_fun
          map_fun' = Lambda (lambdaIndex map_fun) map_params map_body map_rettype

          red_params = lambdaParams map_fun
          red_body = lambdaBody map_fun
          red_rettype = lambdaReturnType map_fun
          red_fun' = Lambda (lambdaIndex red_fun) red_params red_body red_rettype
          red_input' = map (first Var) $
                       uncurry zip $ splitAt (length arrs') $ map paramName map_params

          map_body = mkBody [Let (stripPatternOuterDim $ bindingPattern bnd) () $
                             Op $ Reduce cs w red_fun' red_input']
                            res

      addBinding $ Let res_pat () $ Op $ Map map_cs map_w map_fun' map_arrs'
  | otherwise = Nothing

removeParamOuterDim :: LParam -> LParam
removeParamOuterDim param =
  let t = rowType $ paramType param
  in param { paramAttr = t }

setParamOuterDimTo :: SubExp -> LParam -> LParam
setParamOuterDimTo w param =
  let t = setOuterDimTo w $ paramType param
  in param { paramAttr = t }

setIdentOuterDimTo :: SubExp -> Ident -> Ident
setIdentOuterDimTo w ident =
  let t = setOuterDimTo w $ identType ident
  in ident { identType = t }

setOuterDimTo :: SubExp -> Type -> Type
setOuterDimTo w t =
  arrayOfRow (rowType t) w

setPatternOuterDimTo :: SubExp -> Pattern -> Pattern
setPatternOuterDimTo w pat =
  basicPattern' [] $ map (setIdentOuterDimTo w) $ patternValueIdents pat

transposeIdentType :: Ident -> Ident
transposeIdentType ident =
  ident { identType = transposeType $ identType ident }

stripIdentOuterDim :: Ident -> Ident
stripIdentOuterDim ident =
  ident { identType = rowType $ identType ident }

stripPatternOuterDim :: Pattern -> Pattern
stripPatternOuterDim pat =
  basicPattern' [] $ map stripIdentOuterDim $ patternValueIdents pat
