{-# language OverloadedStrings #-}
module Typechecker where

import Control.Monad (replicateM)
import Control.Monad.State (State, runState, get, put, gets, modify)
import Control.Monad.Except (ExceptT, runExceptT, throwError)
import Data.Maybe (fromMaybe)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import AST (Type(..), Scheme(..), Exp(..), Lit(..), prettyType, prettyScheme)

type Substitution = Map Text Type

emptySubst :: Substitution
emptySubst = Map.empty

applySubst :: Substitution -> Type -> Type
applySubst subst ty = case ty of
  TVar var ->
    fromMaybe (TVar var) (Map.lookup var subst)
  TFun t1 t2 ->
    TFun (applySubst subst t1) (applySubst subst t2)
  TInt -> TInt
  TBool -> TBool

applySubstScheme :: Substitution -> Scheme -> Scheme
applySubstScheme subst (Scheme vars t) =
  -- The fold takes care of name shadowing
  Scheme vars (applySubst (foldr Map.delete subst vars) t)

-- | This is much more subtle than it seems. (union is left biased)
--
-- TODO(Christoph) explain why composition is much "simpler" in the
-- math and gets complicated if you always flatten into a single map
-- (hint: invariant is that you never need to use "fix" to apply a
-- substitution)
composeSubst :: Substitution -> Substitution -> Substitution
composeSubst s1 s2 = Map.union (Map.map (applySubst s1) s2) s1

type TI a = ExceptT Text (State Int) a

runTI :: TI a -> (Either Text a, Int)
runTI ti = runState (runExceptT ti) 0

-- | Creates a fresh type variable
newTyVar :: TI Type
newTyVar = do
  s <- get
  put (s + 1)
  pure (TVar ("u" <> showT s))

freeTypeVars :: Type -> Set Text
freeTypeVars ty = case ty of
 TVar var ->
   Set.singleton var
 TFun t1 t2 ->
   Set.union (freeTypeVars t1) (freeTypeVars t2)
 _ ->
   Set.empty

freeTypeVarsScheme :: Scheme -> Set Text
freeTypeVarsScheme (Scheme vars t) =
  Set.difference (freeTypeVars t) (Set.fromList vars)

-- | Creates a fresh unification variable and binds it to the given type
varBind :: Text -> Type -> TI Substitution
varBind var ty
  | ty == TVar var = pure emptySubst
  | Set.member var (freeTypeVars ty) = throwError "occurs check failed"
  | otherwise = pure (Map.singleton var ty)

unify :: Type -> Type -> TI Substitution
unify ty1 ty2 = case (ty1, ty2) of
  (TInt, TInt) -> pure emptySubst
  (TBool, TBool) -> pure emptySubst
  (TVar u, t) -> varBind u t
  (t, TVar u) -> varBind u t
  (TFun l r, TFun l' r') -> do
    s1 <- unify l l'
    s2 <- unify (applySubst s1 r) (applySubst s1 r')
    pure (s1 `composeSubst` s2)
  (t1, t2) ->
    throwError ("types do not unify: " <> showT t1 <> " vs. " <> showT t2)

type Context = Map Text Scheme

applySubstCtx :: Substitution -> Context -> Context
applySubstCtx subst ctx = Map.map (applySubstScheme subst) ctx

freeTypeVarsCtx :: Context -> Set Text
freeTypeVarsCtx ctx = foldMap freeTypeVarsScheme (Map.elems ctx)

generalize :: Context -> Type -> Scheme
generalize ctx t = Scheme vars t
  where
    vars = Set.toList (Set.difference (freeTypeVars t) (freeTypeVarsCtx ctx))

instantiate :: Scheme -> TI Type
instantiate (Scheme vars ty) = do
  newVars <- replicateM (length vars) newTyVar
  let subst = Map.fromList (zip vars newVars)
  pure (applySubst subst ty)

inferLiteral :: Lit -> TI (Substitution, Type)
inferLiteral lit =
  pure (emptySubst, case lit of
    LInt _ -> TInt
    LBool _ -> TBool)

infer :: Context -> Exp -> TI (Substitution, Type)
infer ctx exp = case exp of
  EVar var -> case Map.lookup var ctx of
    Nothing ->
      throwError ("unbound variable: " <> showT var)
    Just ty -> do
      t <- instantiate ty
      pure (emptySubst, t)
  ELit lit ->
    inferLiteral lit
  EApp fun arg -> do
    (s0, tyFun) <- infer ctx fun
    (s1, tyArg) <- infer (applySubstCtx s0 ctx) arg
    tyRes <- newTyVar
    s2 <- unify (applySubst s1 tyFun) (TFun tyArg tyRes)
    pure (s2 `composeSubst` s1 `composeSubst` s0, applySubst s2 tyRes)
  EAbs binder body -> do
    tyBinder <- newTyVar
    let tmpCtx = Map.insert binder (Scheme [] tyBinder) ctx
    (s1, tyBody) <- infer tmpCtx body
    -- TODO(Christoph): Does this mean we keep a substitution for the
    -- (now out of scope) lambda argument in the substitution around?
    --
    -- Answer: Yes it does, but it might be a good idea to explain why
    pure (s1, TFun (applySubst s1 tyBinder) tyBody)
  ELet binder binding body -> do
    (s1, tyBinder) <- infer ctx binding
    -- let t' = generalize ctx (applySubst s1 t1)
    let t' = Scheme [] (applySubst s1 tyBinder)
    let tmpCtx = Map.insert binder t' ctx
    (s2, tyBody) <- infer (applySubstCtx s1 tmpCtx) body
    pure (composeSubst s1 s2, tyBody)

{- Inference without plumbing
EApp fun arg -> do
  tyFun <- infer ctx fun
  tyArg <- infer ctx arg
  tyRes <- newTyVar "res"
  unify tyFun (TFun tyArg tyRes)
  pure tyRes

EAbs binder body -> do
   tyBinder <- newTyVar "x"
   let tmpCtx = Map.insert binder (Scheme [] tyBinder) ctx
   tyBody <- infer tmpCtx body
   pure (TFun tyArg tyBody)

ELet binder binding body -> do
  tyBinder <- infer ctx binding
  let tmpCtx = Context (Map.insert binder (Scheme [] tyBinder) ctx')
  tyBody <- infer tmpCtx body
  pure tyBody
-}
typeInference :: Context -> Exp -> TI Type
typeInference ctx exp = do
  (s, t) <- infer ctx exp
  pure (applySubst s t)

primitives :: Context
primitives = Map.fromList
  [ ("identity", Scheme ["l"] (TFun (TVar "l") (TVar "l")))
  , ("const", Scheme ["r", "l"] (TFun (TVar "r") (TFun (TVar "l") (TVar "r"))))
  , ("add", Scheme [] (TFun TInt (TFun TInt TInt)))
  , ("gte", Scheme [] (TFun TInt (TFun TInt TBool)))
  , ("if", Scheme ["l"] (TFun TBool (TFun (TVar "l") (TFun (TVar "l") (TVar "l")))))
  ]

testTI :: Exp -> IO ()
testTI e = do
  let (res, _) = runTI (typeInference primitives e)
  case res of
    Left err -> putStrLn $ show e ++ "\n " ++ Text.unpack err ++ "\n"
    Right t  -> putStrLn $ "\n" ++ Text.unpack (prettyScheme (generalize Map.empty t)) ++ "\n"

showT :: Show a => a -> Text
showT = Text.pack . show
