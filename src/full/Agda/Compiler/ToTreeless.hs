{-# LANGUAGE CPP                 #-}
{-# LANGUAGE DoAndIfThenElse     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE PatternGuards       #-}

module Agda.Compiler.ToTreeless
  ( ccToTreeless
  , closedTermToTreeless
  ) where

import Control.Applicative
import Control.Monad.Reader
import Data.Maybe
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Traversable (traverse)

import Agda.Syntax.Common
import Agda.Syntax.Internal (QName)
import qualified Agda.Syntax.Treeless as C
import qualified Agda.Syntax.Internal as I
import Agda.Syntax.Literal
import qualified Agda.TypeChecking.CompiledClause as CC
import Agda.TypeChecking.Records (getRecordConstructor)
import Agda.TypeChecking.Pretty
import Agda.TypeChecking.CompiledClause

import Agda.Compiler.Treeless.Builtin
import Agda.Compiler.Treeless.Simplify
import Agda.Compiler.Treeless.Erase
import Agda.Compiler.Treeless.Uncase
import Agda.Compiler.Treeless.Pretty

import Agda.Syntax.Common
import Agda.TypeChecking.Monad as TCM
import Agda.TypeChecking.Reduce
import Agda.TypeChecking.Substitute

import Agda.Utils.Functor
import qualified Agda.Utils.HashMap as HMap
import Agda.Utils.List
import Agda.Utils.Maybe
import Agda.Utils.Monad
import qualified Agda.Utils.Pretty as P

#include "undefined.h"
import Agda.Utils.Impossible

prettyPure :: P.Pretty a => a -> TCM Doc
prettyPure = return . P.pretty

-- | Converts compiled clauses to treeless syntax.
ccToTreeless :: QName -> CC.CompiledClauses -> TCM (Maybe C.TTerm)
ccToTreeless q cc = ifM (alwaysInline q) (pure Nothing) $ Just <$> do
  reportSDoc "treeless.opt" 20 $ text "-- compiling" <+> prettyTCM q
  reportSDoc "treeless.convert" 30 $ text "-- compiled clauses:" $$ nest 2 (prettyPure cc)
  body <- casetreeTop cc
  reportSDoc "treeless.opt.converted" 30 $ text "-- converted body:" $$ nest 2 (prettyPure body)
  body <- simplifyTTerm body
  reportSDoc "treeless.opt.simpl" 35 $ text "-- after first simplification"  $$ nest 2 (prettyPure body)
  body <- translateBuiltins body
  reportSDoc "treeless.opt.builtin" 30 $ text "-- after builtin translation:" $$ nest 2 (prettyPure body)
  body <- simplifyTTerm body
  reportSDoc "treeless.opt.simpl" 30 $ text "-- after second simplification"  $$ nest 2 (prettyPure body)
  body <- eraseTerms body
  reportSDoc "treeless.opt.erase" 30 $ text "-- after erasure"  $$ nest 2 (prettyPure body)
  body <- caseToSeq body
  reportSDoc "treeless.opt.uncase" 30 $ text "-- after uncase"  $$ nest 2 (prettyPure body)
  return body

closedTermToTreeless :: I.Term -> TCM C.TTerm
closedTermToTreeless t = do
  substTerm t `runReaderT` initCCEnv

alwaysInline :: QName -> TCM Bool
alwaysInline q = do
  def <- theDef <$> getConstInfo q
  pure $ case def of  -- always inline with functions and pattern lambdas
    Function{} -> isJust (funExtLam def) || isJust (funWith def)
    _ -> False

-- | Initial environment for expression generation.
initCCEnv :: CCEnv
initCCEnv = CCEnv
  { ccCxt        = []
  , ccCatchAll   = Nothing
  }

-- | Environment for naming of local variables.
data CCEnv = CCEnv
  { ccCxt        :: CCContext  -- ^ Maps case tree de-bruijn indices to TTerm de-bruijn indices
  , ccCatchAll   :: Maybe Int  -- ^ TTerm de-bruijn index of the current catch all
  -- If an inner case has no catch-all clause, we use the one from its parent.
  }

type CCContext = [Int]
type CC = ReaderT CCEnv TCM

shift :: Int -> CCContext -> CCContext
shift n = map (+n)

-- | Term variables are de Bruijn indices.
lookupIndex :: Int -- ^ Case tree de bruijn index.
    -> CCContext
    -> Int -- ^ TTerm de bruijn index.
lookupIndex i xs = fromMaybe __IMPOSSIBLE__ $ xs !!! i

-- | Case variables are de Bruijn levels.
lookupLevel :: Int -- ^ case tree de bruijn level
    -> CCContext
    -> Int -- ^ TTerm de bruijn index
lookupLevel l xs = fromMaybe __IMPOSSIBLE__ $ xs !!! (length xs - 1 - l)

-- | Compile a case tree into nested case and record expressions.
casetreeTop :: CC.CompiledClauses -> TCM C.TTerm
casetreeTop cc = flip runReaderT initCCEnv $ do
  let a = commonArity cc
  lift $ reportSLn "treeless.convert.arity" 40 $ "-- common arity: " ++ show a
  lambdasUpTo a $ casetree cc

casetree :: CC.CompiledClauses -> CC C.TTerm
casetree cc = do
  case cc of
    CC.Fail -> return C.tUnreachable
    CC.Done xs v -> lambdasUpTo (length xs) $ do
        v <- lift $ putAllowedReductions [ProjectionReductions, CopatternReductions, InlineReductions] $ normalise v
        substTerm v
    CC.Case n (CC.Branches True conBrs _ _) -> lambdasUpTo n $ do
      mkRecord =<< traverse casetree (CC.content <$> conBrs)
    CC.Case n (CC.Branches False conBrs litBrs catchAll) -> lambdasUpTo (n + 1) $ do
      if Map.null conBrs && Map.null litBrs then do
        -- there are no branches, just return default
        fromMaybe C.tUnreachable
          <$> (fmap C.TVar <$> asks ccCatchAll)
      else do
        caseTy <- case (Map.keys conBrs, Map.keys litBrs) of
              ((c:_), []) -> do
                c' <- lift (canonicalName c)
                dtNm <- conData . theDef <$> lift (getConstInfo c')
                return $ C.CTData dtNm
              ([], (LitChar _ _):_)  -> return C.CTChar
              ([], (LitString _ _):_) -> return C.CTString
              ([], (LitQName _ _):_) -> return C.CTQName
              _ -> __IMPOSSIBLE__
        updateCatchAll catchAll $ do
          x <- lookupLevel n <$> asks ccCxt
          -- normally, Agda should make sure that a pattern match is total,
          -- so we set the default to unreachable if no default has been provided.
          def <- fromMaybe C.tUnreachable
            <$> (fmap C.TVar <$> asks ccCatchAll)
          C.TCase x caseTy def <$> do
            br1 <- conAlts n conBrs
            br2 <- litAlts n litBrs
            return (br1 ++ br2)

commonArity :: CC.CompiledClauses -> Int
commonArity cc =
  case arities 0 cc of
    [] -> 0
    as -> minimum as
  where
    arities cxt (Case x (Branches False cons lits def)) =
      concatMap (wArities cxt') (Map.elems cons) ++
      concatMap (wArities cxt' . WithArity 0) (Map.elems lits) ++
      concat [ arities cxt' c | Just c <- [def] ] -- ??
      where cxt' = max (x + 1) cxt
    arities cxt (Case _ (Branches True _ _ _)) = [cxt]
    arities cxt (Done xs _) = [max cxt (length xs)]
    arities _   Fail        = []


    wArities cxt (WithArity k c) = map (\ x -> x - k + 1) $ arities (cxt - 1 + k) c

updateCatchAll :: Maybe CC.CompiledClauses -> (CC C.TTerm -> CC C.TTerm)
updateCatchAll Nothing cont = cont
updateCatchAll (Just cc) cont = do
  def <- casetree cc
  local (\e -> e { ccCatchAll = Just 0, ccCxt = shift 1 (ccCxt e) }) $ do
    C.mkLet def <$> cont

lambdasUpTo :: Int -> CC C.TTerm -> CC C.TTerm
lambdasUpTo n cont = do
  diff <- (n -) . length <$> asks ccCxt

  if diff <= 0 then cont -- no new lambdas needed
  else do
    catchAll <- asks ccCatchAll

    local (\e -> e { ccCxt = [0..(diff - 1)] ++ shift diff (ccCxt e)}) $ do
      createLambdas diff <$> do
        case catchAll of
          Just catchAll' -> do
            -- the catch all doesn't know about the additional lambdas, so just directly
            -- apply it again to the newly introduced lambda arguments.
            -- we also bind the catch all to a let, to avoid code duplication
            local (\e -> e { ccCatchAll = Just 0
                           , ccCxt = shift 1 (ccCxt e)}) $ do
              let catchAllArgs = map C.TVar $ reverse [0..(diff - 1)]
              C.mkLet (C.mkTApp (C.TVar $ catchAll' + diff) catchAllArgs)
                <$> cont
          Nothing -> cont
  where createLambdas :: Int -> C.TTerm -> C.TTerm
        createLambdas 0 cont' = cont'
        createLambdas i cont' | i > 0 = C.TLam (createLambdas (i - 1) cont')
        createLambdas _ _ = __IMPOSSIBLE__

conAlts :: Int -> Map QName (CC.WithArity CC.CompiledClauses) -> CC [C.TAlt]
conAlts x br = forM (Map.toList br) $ \ (c, CC.WithArity n cc) -> do
  c' <- lift $ canonicalName c
  replaceVar x n $ do
    branch (C.TACon c' n) cc

litAlts :: Int -> Map Literal CC.CompiledClauses -> CC [C.TAlt]
litAlts x br = forM (Map.toList br) $ \ (l, cc) ->
  -- Issue1624: we need to drop the case scrutinee from the environment here!
  replaceVar x 0 $ do
    branch (C.TALit l ) cc

branch :: (C.TTerm -> C.TAlt) -> CC.CompiledClauses -> CC C.TAlt
branch alt cc = do
  alt <$> casetree cc

-- | Replace de Bruijn Level @x@ by @n@ new variables.
replaceVar :: Int -> Int -> CC a -> CC a
replaceVar x n cont = do
  let upd cxt = shift n ys ++ ixs ++ shift n zs
       where
         -- compute the de Bruijn index
         i = length cxt - 1 - x
         -- discard index i
         (ys, _:zs) = splitAt i cxt
         -- compute the de-bruijn indexes of the newly inserted variables
         ixs = [0..(n - 1)]
  local (\e -> e { ccCxt = upd (ccCxt e) , ccCatchAll = (+n) <$> ccCatchAll e }) $
    cont


-- | Precondition: Map not empty.
mkRecord :: Map QName C.TTerm -> CC C.TTerm
mkRecord fs = lift $ do
  -- Get the name of the first field
  let p1 = fst $ fromMaybe __IMPOSSIBLE__ $ headMaybe $ Map.toList fs
  -- Use the field name to get the record constructor and the field names.
  I.ConHead c _ind xs <- conSrcCon . theDef <$> (getConstInfo =<< canonicalName . I.conName =<< recConFromProj p1)
  -- Convert the constructor
  let (args :: [C.TTerm]) = for xs $ \ x -> fromMaybe __IMPOSSIBLE__ $ Map.lookup x fs
  return $ C.mkTApp (C.TCon c) args


recConFromProj :: QName -> TCM I.ConHead
recConFromProj q = do
  caseMaybeM (isProjection q) __IMPOSSIBLE__ $ \ proj -> do
    let d = projFromType proj
    getRecordConstructor d


-- | Translate the actual Agda terms, with an environment of all the bound variables
--   from patternmatching. Agda terms are in de Bruijn indices, but the expected
--   TTerm de bruijn indexes may differ. This is due to additional let-bindings
--   introduced by the catch-all machinery, so we need to lookup casetree de bruijn
--   indices in the environment as well.
substTerm :: I.Term -> CC C.TTerm
substTerm term = case I.ignoreSharing $ I.unSpine term of
    I.Var ind es -> do
      ind' <- lookupIndex ind <$> asks ccCxt
      let args = fromMaybe __IMPOSSIBLE__ $ I.allApplyElims es
      C.mkTApp (C.TVar ind') <$> substArgs args
    I.Lam _ ab ->
      C.TLam <$>
        local (\e -> e { ccCxt = 0 : (shift 1 $ ccCxt e) })
          (substTerm $ I.unAbs ab)
    I.Lit l -> return $ C.TLit l
    I.Level _ -> return C.TUnit -- TODO can we really do this here?
    I.Def q es -> do
      let args = fromMaybe __IMPOSSIBLE__ $ I.allApplyElims es
      maybeInlineDef q args
    I.Con c args -> do
        c' <- lift $ canonicalName $ I.conName c
        C.mkTApp (C.TCon c') <$> substArgs args
    I.Shared _ -> __IMPOSSIBLE__ -- the ignoreSharing fun should already take care of this
    I.Pi _ _ -> return C.TUnit -- TODO return proper pi here
    I.Sort _  -> return C.TSort
    I.MetaV _ _ -> __IMPOSSIBLE__
    I.DontCare _ -> __IMPOSSIBLE__ -- when does this happen?

maybeInlineDef :: I.QName -> I.Args -> CC C.TTerm
maybeInlineDef q vs =
  ifM (lift $ alwaysInline q) doinline $ do
    def <- lift $ theDef <$> getConstInfo q
    case def of
      Function{ funInline = True } -> doinline
      _                            -> noinline
  where
    noinline = C.mkTApp (C.TDef q) <$> substArgs vs
    doinline = C.mkTApp <$> inline q <*> substArgs vs
    inline q = lift $ do
      Just cc <- defCompiled <$> getConstInfo q
      casetreeTop cc

substArgs :: [Arg I.Term] -> CC [C.TTerm]
substArgs = traverse
  (\x -> if isIrrelevant x
            then return C.TErased
            else substTerm (unArg x)
  )
