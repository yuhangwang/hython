{-# LANGUAGE FlexibleContexts #-}

module Hython.Interpreter (interpret)
where

import Prelude hiding (break)

import Control.Monad
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Trans.Cont hiding (cont)
import Data.Bits
import Data.Fixed
import Data.IORef
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as Map
import Data.Maybe
import Debug.Trace
import System.Environment
import System.Exit
import Text.Printf

import Hython.Attributes
import Hython.Builtins hiding (builtins)
import Hython.Classes
import qualified Hython.Builtins (builtins)
import Language.Python.Core
import Language.Python.Parser

type Evaluator = ContT () (ReaderT Config (StateT Environment IO))
type EvaluatorCont = () -> Evaluator ()
type EvaluatorReturnCont = Value -> Evaluator ()
type EvaluatorExceptCont = Value -> Evaluator ()
type SymbolTable = HashMap String Value

data Config = Config {
    tracingEnabled :: Bool
}

data Environment = Environment {
    currentException :: Value,
    exceptHandler :: EvaluatorExceptCont,
    frames :: [Frame],
    scopes :: [SymbolTable],
    builtins :: [(String, Value)],
    fnReturn :: EvaluatorReturnCont,
    loopBreak :: EvaluatorCont,
    loopContinue :: EvaluatorCont
}

data Frame = Frame String SymbolTable

unimplemented :: String -> Evaluator ()
unimplemented s = raiseError "NotImplementedError" (s ++ " not yet implemented")

defaultConfig :: IO Config
defaultConfig = do
    tracing <- lookupEnv "TRACE"

    return Config { tracingEnabled = isJust tracing }

defaultEnv :: IO Environment
defaultEnv = do
    builtinsList <- Hython.Builtins.builtins

    return Environment {
        currentException = None,
        exceptHandler = defaultExceptionHandler,
        builtins = builtinsList,
        frames = [Frame "<module>" (Map.fromList [])],
        scopes = [Map.fromList []],
        fnReturn = defaultReturnHandler,
        loopBreak = defaultBreakHandler,
        loopContinue = defaultContinueHandler
    }

defaultExceptionHandler :: Value -> Evaluator ()
defaultExceptionHandler _exception = liftIO $ do
    putStrLn "Exception: <msg>"
    exitFailure

defaultBreakHandler :: () -> Evaluator ()
defaultBreakHandler () = raiseError "SyntaxError" "'break' outside loop"

defaultContinueHandler :: () -> Evaluator ()
defaultContinueHandler () = raiseError "SyntaxError" "'continue' not properly in loop"

defaultReturnHandler :: Value -> Evaluator ()
defaultReturnHandler _ = raiseError "SyntaxError" "'return' outside function"

currentScope :: Evaluator SymbolTable
currentScope = do
    current <- gets scopes
    return $ head current

lookupSymbol :: String -> Evaluator Value
lookupSymbol name = do
    scope <- currentScope
    case Map.lookup name scope of
        Just v  -> return v
        Nothing -> do
            builtinSymbols <- gets builtins
            case lookup name builtinSymbols of
                Just v  -> return v
                Nothing -> do
                    raiseError "NameError" (printf "name '%s' is not defined" name)
                    return None

removeSymbol :: String -> Evaluator ()
removeSymbol name = do
    scope <- currentScope

    let updatedScope = Map.delete name scope
    modify $ \env -> env { scopes = updatedScope : tail (scopes env) }

updateSymbol :: String -> Value -> Evaluator ()
updateSymbol name value = do
    scope <- currentScope

    let updatedScope = Map.insert name value scope
    modify $ \env -> env { scopes = updatedScope : tail (scopes env) }

raiseError :: String -> String -> Evaluator ()
raiseError errorClassName message = do
    errorClass <- evalExpr (Name errorClassName)
    exception <- evalCall errorClass [String message]
    liftIO $ putStrLn message

    handler <- gets exceptHandler
    handler exception

eval :: Statement -> Evaluator ()
eval (Def name params body) = updateSymbol name function
  where
    function = Function name params body

eval (ModuleDef statements) = evalBlock statements

eval (ClassDef name bases statements) = do
    baseClasses <- evalBases bases
    pushScope
    evalBlock statements
    dict <- popScope
    attributeDict <- liftIO $ newAttributeDict (Map.toList dict)

    updateSymbol name $ Class name baseClasses attributeDict

  where
    evalBases = mapM evalExpr

    pushScope = do
        let dict = Map.empty
        modify $ \env -> env { scopes = dict : scopes env }

    popScope = do
        currentScopes <- gets scopes
        let dict = head currentScopes
        modify $ \e -> e{ scopes = tail currentScopes }
        return dict

eval (Assignment (Name var) expr) = do
    value <- evalExpr expr
    updateSymbol var value

eval (Assignment (Attribute var attr) expr) = do
    value <- evalExpr expr
    target <- evalExpr var
    liftIO $ setAttr attr value target

eval (Assignment{}) = raiseError "SyntaxError" "invalid assignment"

eval (Break) = do
    break <- gets loopBreak
    break ()

eval (Continue) = do
    continue <- gets loopContinue
    continue ()

-- Needs EH to implement iterator protocol
eval (For {}) = do
    unimplemented "for keyword"
    return ()

eval (Global {}) = do
    unimplemented "global keyword"
    return ()

eval (If clauses elseBlock) = evalClauses clauses
  where
    evalClauses [] = evalBlock elseBlock
    evalClauses (IfClause condition block : rest) = do
        result <- evalExpr condition
        if isTrue result
            then evalBlock block
            else evalClauses rest

eval (Nonlocal {}) = do
    unimplemented "nonlocal keyword"
    return ()

eval (Raise expr _from) = do
    exception <- evalExpr expr
    baseException <- evalExpr (Name "BaseException")

    if isSubClass (classOf exception) baseException
        then do
            modify $ \e -> e{ currentException = exception }

            handler <- gets exceptHandler
            handler exception
        else raiseError "TypeError" "must raise subclass of BaseException"

eval (Reraise) = do
    exception <- gets currentException

    case exception of
        None -> raiseError "RuntimeError" "No active exception to reraise"

        _ -> do
            handler <- gets exceptHandler
            handler exception

eval (Return expression) = do
    value <- evalExpr expression

    returnCont <- gets fnReturn
    returnCont value

eval (Try exceptClauses block elseBlock finallyBlock) = do
    env <- get
    previousHandler <- gets exceptHandler

    exception <- callCC $ \handler -> do
        modify $ \e -> e { exceptHandler = handler, fnReturn = chain e fnReturn, loopBreak = chain e loopBreak, loopContinue = chain e loopContinue }
        evalBlock block
        return None

    -- Unwind stack
    modify $ \e -> e { exceptHandler = previousHandler, frames = unwindTo (frames e) (length $ frames env), scopes = scopes env }

    -- Search for matching handler
    handled <- case exception of
        None -> do
            evalBlock elseBlock
            return True

        _ -> do
            clause <- getClause exceptClauses exception
            case clause of
                Just (ExceptClause _ name handlerBlock) -> do
                    let exceptionBound = name /= ""

                    modify $ \e -> e { exceptHandler = chainExceptHandler previousHandler (exceptHandler e) }
                    when exceptionBound $ updateSymbol name exception

                    evalBlock handlerBlock

                    when exceptionBound $ removeSymbol name
                    modify $ \e -> e { exceptHandler = previousHandler }

                    return True

                Nothing -> return False

    modify $ \e -> e { exceptHandler = previousHandler }
    evalBlock finallyBlock

    unless handled $
        previousHandler exception

  where
    chain env fn arg = do
        let handler = fn env
        evalBlock finallyBlock
        handler arg

    chainExceptHandler previous handler arg = do
        modify $ \e -> e{ exceptHandler = previous }
        evalBlock finallyBlock
        handler arg

    getClause [] _ = return Nothing
    getClause (c@(ExceptClause classExpr _ _):clauses) exception = do
        cls <- evalExpr classExpr
        if isSubClass (classOf exception) cls
            then return $ Just c
            else getClause clauses exception

    unwindTo stackFrames depth
      | length stackFrames > depth  = unwindTo (tail stackFrames) depth
      | otherwise                   = stackFrames

eval (While condition block elseBlock) = do
    env <- get

    callCC $ \breakCont ->
        fix $ \loop -> do
            callCC $ \continueCont -> do
                let breakHandler = restoreHandler env breakCont
                let continueHandler = restoreHandler env continueCont

                modify $ \e -> e{ loopBreak = breakHandler, loopContinue = continueHandler }

                result <- evalExpr condition
                unless (isTrue result) $ do
                    evalBlock elseBlock
                    breakHandler ()
                evalBlock block
            loop
  where
    -- TODO: shouldn't we be putting the previous break/continue back?
    restoreHandler env cont value = do
        modify $ \e -> e{ exceptHandler = exceptHandler env }
        cont value

eval (With {}) = do
    unimplemented "with keyword"
    return ()

eval (Pass) = return ()

eval (Assert e _) = do
    result <- evalExpr e

    unless (isTrue result) $
        raiseError "AssertionError" ""

eval (Del {}) = do
    unimplemented "del keyword"
    return ()

eval (Expression e) = do
    _ <- evalExpr e
    return ()

evalExpr :: Expression -> Evaluator Value
evalExpr (As expr binding) = do
    value <- evalExpr expr

    case binding of
        Name n  -> updateSymbol n value
        _       -> fail "unhandled binding type"

    return value

evalExpr (UnaryOp Not (Constant (Bool v))) =
    return $ Bool (not v)

evalExpr (UnaryOp Pos (Constant v@(Int {}))) =
    return v

evalExpr (UnaryOp Pos (Constant v@(Float {}))) =
    return v

evalExpr (UnaryOp Neg (Constant (Int v))) =
    return $ Int (- v)

evalExpr (UnaryOp Neg (Constant (Float v))) =
    return $ Float (- v)

evalExpr (UnaryOp Complement (Constant (Int v))) =
    return $ Int (complement v)

evalExpr (UnaryOp op (Constant r)) = do
    strExpr <- liftIO $ str r
    fail $ printf "Unsupported operand type for %s: %s" (show op) strExpr

evalExpr (UnaryOp op expr) = do
    r <- evalExpr expr
    evalExpr $ UnaryOp op (Constant r)

evalExpr (BinOp (ArithOp op) (Constant (Int l)) (Constant (Int r)))
    | op == Add = return $ Int (l + r)
    | op == Sub = return $ Int (l - r)
    | op == Mul = return $ Int (l * r)
    | op == Div = return $ Float (fromInteger l / fromInteger r)
    | op == Mod = return $ Int (l `mod` r)
    | op == FDiv = return $ Int (floorInt (fromIntegral l / fromIntegral r))
    | op == Pow = liftIO $ pow [Int l, Int r]
  where
    floorInt = floor :: Double -> Integer

evalExpr (BinOp (BitOp BitAnd) (Constant (Int l)) (Constant (Int r))) =
    return $ Int (l .&. r)

evalExpr (BinOp (BitOp BitOr) (Constant (Int l)) (Constant (Int r))) =
    return $ Int (l .|. r)

evalExpr (BinOp (BitOp BitXor) (Constant (Int l)) (Constant (Int r))) =
    return $ Int (xor l r)

evalExpr (BinOp (BitOp LShift) (Constant (Int l)) (Constant (Int r))) =
    return $ Int (shiftL l (fromIntegral r))

evalExpr (BinOp (BitOp RShift) (Constant (Int l)) (Constant (Int r))) =
    return $ Int (shiftR l (fromIntegral r))

evalExpr (BinOp (ArithOp op) (Constant (Float l)) (Constant (Float r)))
    | op == Add = return $ Float (l + r)
    | op == Sub = return $ Float (l - r)
    | op == Mul = return $ Float (l * r)
    | op == Div = return $ Float (l / r)
    | op == Mod = return $ Float (l `mod'` r)
    | op == FDiv = return $ Float (fromInteger (floor (l / r)))
    | op == Pow = liftIO $ pow [Float l, Float r]

-- Promote ints to floats in binary operators
evalExpr (BinOp op (Constant (Int l)) (Constant (Float r))) =
    evalExpr $ BinOp op (Constant (Float (fromIntegral l))) (Constant (Float r))

evalExpr (BinOp op (Constant (Float l)) (Constant (Int r))) =
    evalExpr $ BinOp op (Constant (Float l)) (Constant (Float (fromIntegral r)))

-- String + String
evalExpr (BinOp (ArithOp Add) (Constant (String l)) (Constant (String r))) =
    return $ String (l ++ r)

-- Int * String
evalExpr (BinOp (ArithOp Mul) (Constant (Int l)) (Constant (String r))) =
    return $ String (concat $ replicate (fromInteger l) r)

-- String * Int
evalExpr (BinOp (ArithOp Mul) (Constant (String l)) (Constant (Int r))) =
    return $ String (concat $ replicate (fromInteger r) l)

-- Int [=|!=|<|<=|>|>=] Int
evalExpr (BinOp (CompOp op) (Constant (Int l)) (Constant (Int r))) =
    return $ Bool (fn op l r)
  where
    fn Eq               = (==)
    fn NotEq            = (/=)
    fn LessThan         = (<)
    fn LessThanEq       = (<=)
    fn GreaterThan      = (>)
    fn GreaterThanEq    = (>=)

evalExpr (BinOp (CompOp op) (Constant (Float l)) (Constant (Float r))) =
    return $ Bool (fn op l r)
  where
    fn Eq               = (==)
    fn NotEq            = (/=)
    fn LessThan         = (<)
    fn LessThanEq       = (<=)
    fn GreaterThan      = (>)
    fn GreaterThanEq    = (>=)

evalExpr (BinOp (CompOp Eq) (Constant l) (Constant r)) =
    return $ Bool (l == r)

evalExpr (BinOp (CompOp NotEq) (Constant l) (Constant r)) =
    return $ Bool (l /= r)

evalExpr (BinOp op (Constant l) (Constant r)) = do
    left <- liftIO $ str l
    right <- liftIO $ str r
    fail $ printf "Unsupported operand type(s) for %s: %s %s" (show op) left right

evalExpr (BinOp op l r) = do
    left <- evalExpr l
    right <- evalExpr r
    evalExpr $ BinOp op (Constant left) (Constant right)

evalExpr (Call (Attribute obj name) args) = do
    receiver <- evalExpr obj
    evalArgs <- mapM evalExpr args
    method <- liftIO $ getAttr name receiver

    case method of
        Just f  -> evalCall f (receiver: evalArgs)
        Nothing -> fail $ "Unknown method: " ++ name

evalExpr (Call e args) = do
    f <- evalExpr e
    evalArgs <- mapM evalExpr args
    evalCall f evalArgs

evalExpr (Lambda {}) = do
    unimplemented "lambda exprs"
    return None

evalExpr (Attribute target name) = do
    receiver <- evalExpr target
    attribute <- liftIO $ getAttr name receiver
    case attribute of
        Just v  -> return v
        Nothing -> do
            raiseError "AttributeError" (printf "object has no attribute '%s'" name)
            return None

evalExpr (SliceDef startExpr stopExpr strideExpr) = do
    start <- evalExpr startExpr
    stop <- evalExpr stopExpr
    stride <- evalExpr strideExpr

    return $ Slice start stop stride

evalExpr (ListDef exprs) = do
    values <- mapM evalExpr exprs
    ref <- liftIO $ newIORef values
    return $ List ref

evalExpr (Subscript expr sub) = do
    left <- evalExpr expr
    index <- evalExpr sub
    evalSubscript left index

  where
    evalSubscript (List ref) (Int i) = do
        values <- liftIO $ readIORef ref
        return $ values !! fromIntegral i
    evalSubscript (List {}) _ = do
        raiseError "TypeError" "list indicies must be integers"
        return None
    evalSubscript (Tuple values) (Int i) = return $ values !! fromIntegral i
    evalSubscript (Tuple {}) _ = do
        raiseError "TypeError" "tuple indicies must be integers"
        return None
    evalSubscript (String s) (Int i) = return $ String [s !! fromIntegral i]
    evalSubscript _ _ = do
        raiseError "TypeError" "object is not subscriptable"
        return None

evalExpr (TernOp condExpr thenExpr elseExpr) = do
    condition <- evalExpr condExpr
    evalExpr $ if isTrue condition
        then thenExpr
        else elseExpr

evalExpr (TupleDef exprs) = do
    values <- mapM evalExpr exprs
    return $ Tuple values

evalExpr (From {}) = do
    unimplemented "from expr"
    return None

evalExpr (Yield {}) = do
    unimplemented "yield expr"
    return None

evalExpr (Name var) = lookupSymbol var
evalExpr (Constant c) = return c

evalBlock :: [Statement] -> Evaluator ()
evalBlock = mapM_ traceEval
  where
    traceEval :: Statement -> Evaluator ()
    traceEval s = do
        tracing <- asks tracingEnabled
        if tracing
            then (trace $ traceStmt s) eval s
            else eval s

    traceStmt s = "*** Evaluating: " ++ show s

evalCall :: Value -> [Value] -> Evaluator Value
evalCall cls@(Class {}) args = do
    object <- liftIO $ newObject cls

    ctor <- liftIO $ getAttr "__init__" cls
    _ <- case ctor of
        Just f  -> evalCall f (object : args)
        Nothing -> return None

    return object

evalCall (BuiltinFn name) args = do
    let fn = lookup name builtinFunctions
    when (isNothing fn) $
        raiseError "NameError" ("no built-in with name " ++ name)

    liftIO $ fromJust fn args

evalCall (Function name params body) args = do
    env <- get

    currentScopes <- gets scopes
    let scope = Map.union (Map.fromList $ zip params args) $ last currentScopes

    callCC $ \returnCont -> do
        let returnHandler returnValue = do
            put env
            returnCont returnValue

        modify $ \e -> e{ frames = Frame name scope : frames e, fnReturn = returnHandler, scopes = scope : currentScopes }
        evalBlock body
        returnHandler None

        return None

evalCall v _ = do
    s <- liftIO $ str v
    raiseError "SystemError" ("don't know how to call " ++ s)
    return None

interpret :: String -> String -> IO ()
interpret _source code = do
    config  <- defaultConfig
    env     <- defaultEnv

    _ <- runStateT (runReaderT (runContT parseEval return) config) env
    return ()

  where
    parseEval = eval (parse code)
