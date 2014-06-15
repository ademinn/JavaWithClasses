module Generator where

import qualified LLVM.General.AST as A
import qualified LLVM.General.AST.Type as T
import qualified LLVM.General.AST.Constant as C
import qualified LLVM.General.AST.Instruction as I
import qualified LLVM.General.AST.IntegerPredicate as IP
import qualified LLVM.General.AST.FloatingPointPredicate as FPP
import qualified LLVM.General.AST.Global as G

import Control.Applicative
import Control.Monad.State

import Data.Maybe

import Scope
import AST
import Analyzer
import Type
import Codegen
import Native

type EStatement = Either (A.BasicBlock -> [A.BasicBlock]) [A.BasicBlock]

castPrimatyTypeOperand :: (PrimaryType, A.Operand) -> PrimaryType -> Codegen A.Operand
castPrimatyTypeOperand (ot, op) t = if ot == t then return op else addInstr $ f t op (mapPrimaryType t) []
    where
        f TInt = I.SExt
        f TLong = I.SExt
        f TFloat = I.FPExt
        f TDouble = I.FPExt
        f _ = error "cast primary type operand"

castOperand :: (Type, A.Operand) -> Type -> Codegen A.Operand
castOperand (NullType, _) (ObjectType t) = return . nullConstant $ t
castOperand (PrimaryType pt, op) (PrimaryType t) = castPrimatyTypeOperand (pt, op) t
castOperand (ObjectType ot, op) (ObjectType t) = if ot == t then return op else error "cast operand"
castOperand _ _ = error "cast operand"

castList :: [(Type, A.Operand)] -> [Type] -> Codegen [A.Operand]
castList ops ts = forM (zip ops ts) (uncurry castOperand)

inferOperand :: (Type, A.Operand) -> (Type, A.Operand) -> Codegen (Type, (A.Operand, A.Operand))
inferOperand (t1, o1) (t2, o2) = do
    let t = fromJust $ infer t1 t2
    r1 <- castOperand (t1, o1) t
    r2 <- castOperand (t2, o2) t
    return (t, (r1, r2))

genTypedBinaryOpM
    :: Expression -> Expression
    -> (Type -> A.Operand -> A.Operand -> Codegen I.Instruction)
    -> Codegen (Maybe (Type, A.Operand))
genTypedBinaryOpM expr1 expr2 f = do
    e1 <- fromJust <$> genExpression expr1
    e2 <- fromJust <$> genExpression expr2
    (t, (o1, o2)) <- inferOperand e1 e2
    i <- f t o1 o2
    r <- addInstr i
    return $ Just (t, r)

genTypedBinaryOp
    :: Expression -> Expression
    -> (Type -> A.Operand -> A.Operand -> I.Instruction)
    -> Codegen (Maybe (Type, A.Operand))
genTypedBinaryOp expr1 expr2 f = genTypedBinaryOpM expr1 expr2 $ \t o1 o2 -> return $ f t o1 o2

genBinaryOp
    :: Expression -> Expression
    -> (A.Operand -> A.Operand -> I.Instruction)
    -> Codegen (Maybe (Type, A.Operand))
genBinaryOp expr1 expr2 f = genTypedBinaryOp expr1 expr2 $ const f

genCmpOp
    :: Expression -> Expression
    -> IP.IntegerPredicate -> FPP.FloatingPointPredicate
    -> Codegen (Maybe (Type, A.Operand))
genCmpOp e1 e2 ip fpp = genTypedBinaryOpM e1 e2 f
    where
        f (PrimaryType TFloat) o1 o2 = return $ I.FCmp fpp o1 o2 []
        f (PrimaryType TDouble) o1 o2 = return $ I.FCmp fpp o1 o2 []
        f (PrimaryType _) o1 o2 = return $ I.ICmp ip o1 o2 []
        f _ o1 o2 = do
            o1i <- addInstr $ I.PtrToInt o1 (T.IntegerType structPtrSize) []
            o2i <- addInstr $ I.PtrToInt o2 (T.IntegerType structPtrSize) []
            return $ I.ICmp ip o1i o2i []

genArithmOp
    :: Expression -> Expression
    -> (A.Operand -> A.Operand -> I.InstructionMetadata -> I.Instruction)
    -> (A.Operand -> A.Operand -> I.InstructionMetadata -> I.Instruction)
    -> Codegen (Maybe (Type, A.Operand))
genArithmOp expr1 expr2 fi ff = genTypedBinaryOp expr1 expr2 f
    where
        f (PrimaryType TFloat) o1 o2 = ff o1 o2 []
        f (PrimaryType TDouble) o1 o2 = ff o1 o2 []
        f (PrimaryType TBoolean) _ _ = error "genExpression"
        f (PrimaryType _) o1 o2 = fi o1 o2 []
        f _ _ _ = error "genExpression"

genPrePostOp
    :: QualifiedName
    -> (Bool -> Bool -> A.Operand -> A.Operand -> I.InstructionMetadata -> I.Instruction)
    -> Codegen (Type, A.Operand, A.Operand)
genPrePostOp qn f = do
    (t, qPtr) <- fromJust <$> genQualifiedName qn
    qVal <- load qPtr
    newVal <- addInstr $ f False False qVal (oneOp t) []
    store qPtr newVal
    return (t, qVal, newVal)

genPreOp
    :: QualifiedName
    -> (Bool -> Bool -> A.Operand -> A.Operand -> I.InstructionMetadata -> I.Instruction)
    -> Codegen (Maybe (Type, A.Operand))
genPreOp qn f = do
    (t, _, val) <- genPrePostOp qn f
    return $ Just (t, val)

genPostOp
    :: QualifiedName
    -> (Bool -> Bool -> A.Operand -> A.Operand -> I.InstructionMetadata -> I.Instruction)
    -> Codegen (Maybe (Type, A.Operand))
genPostOp qn f = do
    (t, val, _) <- genPrePostOp qn f
    return $ Just (t, val)

genExpression :: Expression -> Codegen (Maybe (Type, A.Operand))
genExpression (Assign qn expr) = do
    (qType, qPtr) <- fromJust <$> genQualifiedName qn
    eRes <- fromJust <$> genExpression expr
    val <- castOperand eRes qType
    store qPtr val
    return $ Just (qType, val)
genExpression (Or e1 e2) = genBinaryOp e1 e2 $ \o1 o2 -> I.Or o1 o2 []
genExpression (And e1 e2) = genBinaryOp e1 e2 $ \o1 o2 -> I.And o1 o2 []
genExpression (Equal e1 e2) = genCmpOp e1 e2 IP.EQ FPP.OEQ
genExpression (Ne e1 e2) = genCmpOp e1 e2 IP.NE FPP.ONE
genExpression (Lt e1 e2) = genCmpOp e1 e2 IP.SLT FPP.OLT
genExpression (Gt e1 e2) = genCmpOp e1 e2 IP.SGT FPP.OGT
genExpression (Le e1 e2) = genCmpOp e1 e2 IP.SLE FPP.OLE
genExpression (Ge e1 e2) = genCmpOp e1 e2 IP.SGE FPP.OGE
genExpression (Plus e1 e2) = genArithmOp e1 e2 (I.Add False False) I.FAdd
genExpression (Minus e1 e2) = genArithmOp e1 e2 (I.Sub False False) I.FSub
genExpression (Mul e1 e2) = genArithmOp e1 e2 (I.Mul False False) I.FMul
genExpression (Div e1 e2) = genArithmOp e1 e2 (I.SDiv False) I.FDiv
genExpression (Mod e1 e2) = genArithmOp e1 e2 I.SRem I.FRem
genExpression (Pos e1) = genExpression e1
genExpression (Neg e1) = genExpression (Minus (Literal $ LInt 0) e1)
genExpression (Not expr) = do
    (t, eRes) <- fromJust <$> genExpression expr
    notE <- addInstr $ I.Sub False False (literalToOp $ LBoolean True) eRes []
    return $ Just (t, notE)
genExpression (PreInc qn) = genPreOp qn I.Add
genExpression (PreDec qn) = genPreOp qn I.Sub
genExpression (PostInc qn) = genPostOp qn I.Add
genExpression (PostDec qn) = genPostOp qn I.Sub
genExpression (QN qn) = do
    qRes <- genQualifiedName qn
    case qRes of
        Nothing -> return Nothing
        Just (qType, qPtr) -> do
            qVal <- load qPtr
            return $ Just (qType, qVal)
genExpression (Literal l) = return $ Just (PrimaryType $ literalType l, literalToOp l)
genExpression Null = return $ Just (NullType, A.ConstantOperand $ C.Null T.VoidType)

callMethod :: ObjectType -> Method -> A.Operand -> [(Type, A.Operand)] -> Codegen I.Instruction
callMethod obj mth this params = do
    paramsOp <- castList params (map paramType $ methodParams mth)
    return $ call (genMethodName obj mth) $ this : paramsOp

genQualifiedName :: QualifiedName -> Codegen (Maybe (Type, A.Operand))
genQualifiedName (FieldAccess qn field) = do
    (t', op) <- fromJust <$> genQualifiedName qn
    let t = objType t'
    (ft, i) <- fromRight "field access" <$> findField t field
    op' <- load op
    retOp <- addInstr $ I.GetElementPtr False op' [structFieldAddr 0, structFieldAddr i] []
    return $ Just (ft, retOp) 
genQualifiedName (MethodCall qn mthName params) = do
    (t', op) <- fromJust <$> genQualifiedName qn
    op' <- load op
    let t = objType t'
    paramsOp <- fmap (map fromJust) . mapM genExpression $ params
    mth <- fromRight "method call" <$> findMethod t mthName (fst $ unzip paramsOp) (\m -> methodType m /= Constructor)
    instr <- callMethod t mth op' paramsOp
    case methodType mth of
        Void -> do
            addVoidInstr instr
            return Nothing
        Constructor -> error "genQualifiedName"
        ReturnType rt -> do
            retOp <- addInstr instr
            ptr <- addInstr $ alloca (mapType rt)
            store ptr retOp
            return $ Just (rt, ptr)
genQualifiedName (Var var) = do
    mv <- lookupLocalVar var
    case mv of
        Just v -> return $ Just v
        Nothing -> genQualifiedName $ FieldAccess This var
genQualifiedName (New ot params) = do
    paramsOp <- fmap (map fromJust) . mapM genExpression $ params
    mth <- fromRight "new" <$> findMethod ot ot (fst $ unzip paramsOp) (\m -> methodType m == Constructor)
    ptr <- new ot
    instr <- callMethod ot mth ptr paramsOp
    retOp <- addInstr instr
    ptr' <- addInstr . alloca . mapType $ ObjectType ot
    store ptr' retOp
    return $ Just (ObjectType ot, ptr')
genQualifiedName This = genQualifiedName (Var "this")

goToBlock :: A.Name -> Codegen A.BasicBlock
goToBlock name = do
    exitLabel <- nextLabel "GoToBlock"
    return $ A.BasicBlock exitLabel [] $ I.Do $ I.Br name []

genIfConsAltOk
    :: A.Name -> A.Operand -> [A.Named I.Instruction]
    -> [A.BasicBlock]
    -> [A.BasicBlock]
    -> [A.BasicBlock]
genIfConsAltOk ifLabel flag calcFlag consBlocks altBlocks = A.BasicBlock ifLabel calcFlag (I.Do $ I.CondBr flag consBlockName altBlockName []) : (consBlocks ++ altBlocks)
    where
        consBlockName = getBBName . head $ consBlocks
        altBlockName = getBBName . head $ altBlocks

genIfCons
    :: A.Name -> A.Operand -> [A.Named I.Instruction]
    -> (A.BasicBlock -> [A.BasicBlock]) -> A.BasicBlock -> [A.BasicBlock]
genIfCons ifLabel flag calcFlag getConsBlocks finBlock = A.BasicBlock ifLabel calcFlag (I.Do $ I.CondBr flag consBlockName finBlockName []) : consBlocks
    where
        finBlockName = getBBName finBlock
        consBlocks = getConsBlocks finBlock
        consBlockName = getBBName . head $ consBlocks

genIfConsAlt
    :: A.Name -> A.Operand -> [A.Named I.Instruction]
    -> (A.BasicBlock -> [A.BasicBlock])
    -> (A.BasicBlock -> [A.BasicBlock])
    -> A.BasicBlock -> [A.BasicBlock]
genIfConsAlt ifLabel flag calcFlag getConsBlocks getAltBlocks finBlock = genIfConsAltOk ifLabel flag calcFlag consBlocks altBlocks
    where
        consBlocks = getConsBlocks finBlock
        altBlocks = getAltBlocks finBlock

getExpressionRes :: Expression -> Codegen (A.Operand, [A.Named I.Instruction])
getExpressionRes e = do
    op <- (snd . fromJust) <$> genExpression e
    calc <- popInstructions
    return (op, calc)

genIf :: If -> Codegen EStatement
genIf (If cond cons alt) = do
    ifLabel <- nextLabel "If"
    (flag, calcFlag) <- getExpressionRes cond
    consBlocks' <- genStatement cons
    let genIfCons' = genIfCons ifLabel flag calcFlag
        genIfConsAlt' = genIfConsAlt ifLabel flag calcFlag
    case (consBlocks', alt) of
        (Left getCons, Nothing) -> return . Left $ genIfCons' getCons
        (Left getCons, Just alt') -> do    
            altBlocks' <- genStatement alt'
            case altBlocks' of
                Left getAlt -> return . Left $ genIfConsAlt' getCons getAlt
                Right altBlocks -> return . Left $ genIfConsAlt' getCons (const altBlocks)
        (Right consBlocks, Nothing) -> return . Left $ genIfCons' $ const consBlocks
        (Right consBlocks, Just alt') -> do
            altBlocks' <- genStatement alt'
            case altBlocks' of
                Left getAlt -> return . Left $ genIfConsAlt' (const consBlocks) getAlt
                Right altBlocks -> return . Right $ genIfConsAltOk ifLabel flag calcFlag consBlocks altBlocks

genWhile :: While -> Codegen (A.BasicBlock -> [A.BasicBlock])
genWhile (While cond st) = do
    whileLabel <- nextLabel "While"
    lastBlock <- goToBlock whileLabel
    endWhileLabel <- nextLabel "EndWhile"
    addLoop (getBBName lastBlock, endWhileLabel)
    (flag, calcFlag) <- getExpressionRes cond
    stBlocks' <- genStatement st
    let stBlocks = case stBlocks' of
            Left f -> f lastBlock
            Right b -> b
        stBlockName = getBBName . head $ stBlocks
    removeLoop
    return $ \finBlock ->
        let finBlockName = getBBName finBlock in
        let endWhile = emptyBlock endWhileLabel $ I.Br finBlockName [] in
        [A.BasicBlock whileLabel calcFlag (I.Do $ I.CondBr flag stBlockName endWhileLabel [])] ++ stBlocks ++ [lastBlock, endWhile]

genExpressionList :: [Expression] -> Codegen ()
genExpressionList = mapM_ genExpression

genVariable :: Variable -> Codegen ()
genVariable (Variable t n e) = do
    ptr <- addNamedInstr (A.Name n) . alloca . mapType $ t
    void $ newLocalVar n (t, ptr)
    case e of
        Just expr -> do
            eRes <- fromJust <$> genExpression expr
            eOp <- castOperand eRes t
            store ptr eOp
        Nothing -> return ()

genForInit :: ForInit -> Codegen ()
genForInit (ForInitEL l) = genExpressionList l
genForInit (ForInitVD v) = genVariable v

genFor :: For -> Codegen (A.BasicBlock -> [A.BasicBlock])
genFor (For fInit cond inc st) = do
    addScope
    initLabel <- nextLabel "ForInit"
    endForLabel <- nextLabel "EndFor"
    forLabel <- nextLabel "For"
    incLabel <- nextLabel "ForInc"
    addLoop (incLabel, endForLabel)
    genForInit fInit
    calcInit <- popInstructions
    (flag, calcFlag) <- getExpressionRes cond
    stBlocks' <- genStatement st
    genExpressionList inc
    calcInc <- popInstructions
    let initBlock = brBlock initLabel forLabel calcInit
        incBlock = brBlock incLabel forLabel calcInc
        stBlocks = case stBlocks' of
            Left f -> f incBlock
            Right b -> b
        stBlockName = getBBName . head $ stBlocks
    removeLoop
    removeScope
    return $ \finBlock ->
        let finBlockName = getBBName finBlock in
        let endFor = emptyBlock endForLabel $ I.Br finBlockName [] in
        [initBlock] ++ [A.BasicBlock forLabel calcFlag (I.Do $ I.CondBr flag stBlockName endForLabel [])] ++ stBlocks ++ [incBlock, endFor]

genStatement :: Statement -> Codegen EStatement
genStatement (SubBlock b) = genBlock b
genStatement (IfStatement st) = genIf st
genStatement (WhileStatement st) = Left <$> genWhile st
genStatement (ForStatement st) = Left <$> genFor st
genStatement (Return mExpr) = do
    retLabel <- nextLabel "Ret"
    case mExpr of
        Nothing -> return . Right . toList . emptyBlock retLabel $ I.Ret Nothing []
        Just expr -> do
            op <- (snd .fromJust ) <$> genExpression expr
            instr <- popInstructions
            return . Right . toList $ A.BasicBlock retLabel instr $ I.Do $ I.Ret (Just op) []
genStatement Break = do
    l <- lastLoopEnd
    breakLabel <- nextLabel "Break"
    return . Right . toList $ emptyBlock breakLabel $ I.Br l []
genStatement Continue = do
    l <- lastLoopNext
    continueLabel <- nextLabel "Continue"
    return . Right . toList $ emptyBlock continueLabel $ I.Br l []
genStatement (ExpressionStatement expr) = do
    void $ genExpression expr
    instr <- popInstructions
    exprLabel <- nextLabel "Expression"
    return . Left $ genBrBlock exprLabel instr

genBlockStatement :: BlockStatement -> Codegen EStatement
genBlockStatement (BlockVD v) = do
    genVariable v
    instr <- popInstructions
    vdLabel <- nextLabel "VarDeclaration"
    return . Left $ genBrBlock vdLabel instr
genBlockStatement (Statement st) = genStatement st

joinEStatements :: [EStatement] -> EStatement
joinEStatements [] = Left $ const []
joinEStatements l = case last l of
    (Right b) -> Right $ foldESt b $ init l
    _ -> Left $ \finBlock -> foldESt [finBlock] l
    where
        joinESt est bl =  case est of
            Left f -> (f . head $ bl) ++ bl
            Right bl' -> bl' ++ bl
        foldESt = foldr joinESt

genBlock :: Block -> Codegen EStatement
genBlock bs = do
    addScope
    res <- joinEStatements <$> forM bs genBlockStatement
    removeScope
    return res

genMethod :: Method -> Codegen A.Definition
genMethod mth@(Method mt _ mp b) = do
    modify $ \s -> s { lastInd = -1, lastLabel = 0, csMethod = Just mth }
    addScope
    curClass <- getClassM
    let params = Parameter (ObjectType . className $ curClass) "this" : mp
    forM_ params genParam
    instr <- popInstructions
    mthInitLabel <- nextLabel "MethodInit"
    fieldsInit <- if mt == Constructor then genFieldsInit else return . Right $ []
    let b' = b ++ [Statement . Return . Just . QN $ This | mt == Constructor]
    blockESt <- genBlock b'
    mthRet <- nextLabel "MethodExit"
    let initESt = Left $ genBrBlock mthInitLabel instr
        est = [initESt, fieldsInit, blockESt] ++ [Right [emptyBlock mthRet $ I.Ret Nothing []] | mt == Void]
        mthBlocks = fromRight "genMethod join" . joinEStatements $ est
    removeScope
    return $ genMethodDefinition curClass mth mthBlocks

genField :: Variable -> Codegen ()
genField (Variable vt vn ve) = do
    let expr = fromMaybe (nullValue vt) ve 
    void $ genExpression $ Assign (FieldAccess This vn) expr

genFieldsInit :: Codegen EStatement
genFieldsInit = do
    cls <- getClassM
    forM_ (classFields cls) genField
    instr <- popInstructions
    fieldInitLabel <- nextLabel "FieldsInit"
    return . Left $ genBrBlock fieldInitLabel instr

genClass :: Class -> Codegen [A.Definition]
genClass cls = do
    modify $ \s -> s { csClass = Just cls }
    let struct = genStruct cls
    methods <- forM (classMethods cls) genMethod
    modify $ \s -> s { csClass = Nothing }
    return $ struct : methods

genProgram :: Program -> Codegen A.Module
genProgram p = do
    modify $ \s -> s { csProgram = Just $ consoleWriter : p }
    defs <- concat <$> forM p genClass
    mainF <- mainFunc
    cw <- genConsoleWriter
    let allDefs = mallocDecl : printfDecl : mainF : (cw ++ defs)
    modify $ \s -> s { csProgram = Nothing }
    return A.defaultModule { A.moduleDefinitions = allDefs }

mainFunc :: Codegen A.Definition
mainFunc = do
    addScope
    let name = "Main"
    mth <- fromRight "new" <$> findMethod name name [] (\m -> methodType m == Constructor)
    ptr <- new name
    i <- callMethod name mth ptr []
    addVoidInstr i
    instr <- popInstructions
    mainLabel <- nextLabel "main"
    let block = A.BasicBlock mainLabel instr $ A.Do $ I.Ret (Just $ A.ConstantOperand $ C.Int 32 0) []
    removeScope
    return . A.GlobalDefinition $ G.functionDefaults
        { G.returnType = T.IntegerType 32
        , G.name = A.Name "main"
        , G.parameters = ([], False)
        , G.basicBlocks = [block]
        }
