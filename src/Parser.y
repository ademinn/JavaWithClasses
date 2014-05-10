{
module Parser where

import Lexer
import AST
import Data.Strict.Tuple
}

%name parse
%tokentype { Token }
%error { parseError }

%token
    class       { Token (TKeyword "class") _    }
    void        { Token (TKeyword "void") _     }
    if          { Token (TKeyword "if") _       }
    else        { Token (TKeyword "else") _     }
    while       { Token (TKeyword "while") _    }
    for         { Token (TKeyword "for") _      }
    break       { Token (TKeyword "break") _    }
    continue    { Token (TKeyword "continue") _ }
    return      { Token (TKeyword "return") _   }
    null        { Token (TKeyword "null") _     }
    this        { Token (TKeyword "this") _     }
    new         { Token (TKeyword "new") _      }
    boolean     { Token (TKeyword "boolean") _  }
    byte        { Token (TKeyword "byte") _     }
    short       { Token (TKeyword "short") _    }
    int         { Token (TKeyword "int") _      }
    long        { Token (TKeyword "long") _     }
    float       { Token (TKeyword "float") _    }
    double      { Token (TKeyword "double") _   }

    "||"        { Token (TOperator "||") _ }
    "&&"        { Token (TOperator "&&") _ }
    "=="        { Token (TOperator "==") _ }
    "!="        { Token (TOperator "!=") _ }
    "<"         { Token (TOperator "<") _ }
    ">"         { Token (TOperator ">") _ }
    "<="        { Token (TOperator "<=") _ }
    ">="        { Token (TOperator ">=") _ }
    "+"         { Token (TOperator "+") _ }
    "-"         { Token (TOperator "-") _ }
    "*"         { Token (TOperator "*") _ }
    "/"         { Token (TOperator "/") _ }
    "%"         { Token (TOperator "%") _ }
    "!"         { Token (TOperator "!") _ }
    "--"        { Token (TOperator "--") _ }
    "++"        { Token (TOperator "++") _ }
    "("         { Token (TOperator "(") _ }
    ")"         { Token (TOperator ")") _ }
    "{"         { Token (TOperator "{") _ }
    "}"         { Token (TOperator "}") _ }
    ","         { Token (TOperator ",") _ }
    ";"         { Token (TOperator ";") _ }
    "."         { Token (TOperator ".") _ }
    "="         { Token (TOperator "=") _ }

    literal     { Token (TLiteral $$) _ }

    identifier  { Token (TIdentifier $$) _ }

%right "="
%left "||"
%left "&&"
%left "==" "!="
%nonassoc "<" ">" "<=" ">="
%left "+" "-"
%left "*" "/" "%"
%left "++" "--" "!" UNARY
%right POSTFIX

%%

Start :: { [Class] }
Start
    : ClassList { $1 }

ClassList :: { [Class] }
ClassList
    : ClassListRev  { reverse $1 }

ClassListRev :: { [Class] }
ClassListRev
    : ClassListRev Class     { $2 : $1 }
    | {- empty -}         { [] }

Class :: { Class }
Class
    : class identifier "{" MemberList "}"       { Class $2 $4 }

MemberList :: { [Member] }
MemberList
    : MemberListRev     { reverse $1 }

MemberListRev :: { [Member] }
MemberListRev
    : MemberListRev Member         { $2 : $1 }
    | {- empty -}           { [] }

Member :: { Member }
Member
    : VariableDeclaration       { MemberVD $1 }
    | MethodDeclaration         { MemberMD $1 }

VariableDeclaration :: { Variable }
VariableDeclaration
    : Type identifier ";"       { Variable $1 $2 Nothing }
    | Type identifier "=" Expression ";"    { Variable $1 $2 (Just $4) }

MethodDeclaration :: { Method }
MethodDeclaration
    : MaybeType identifier "(" ParameterList ")" Block      { Method $1 $2 $4 $6 }

MaybeType :: { MaybeType }
MaybeType
    : Type      { ReturnType $1 }
    | void      { Void }
    | {- empty -}   { Constructor }

ParameterList :: { [Parameter] }
ParameterList
    : ParameterListRev      { reverse $1 }

ParameterListRev :: { [Parameter] }
ParameterListRev
    : ParameterListRev "," Parameter    { $3 : $1 }
    | Parameter     { [$1] }

Parameter :: { Parameter }
Parameter
    : Type identifier   { Parameter $1 $2 }

Block :: { [BlockStatement] }
Block
    : "{" BlockStatementList "}"    { $2 }

BlockStatementList :: { [BlockStatement] }
BlockStatementList
    : BlockStatementListRev     { reverse $1 }

BlockStatementListRev :: { [BlockStatement] }
BlockStatementListRev
    : BlockStatementListRev BlockStatement  { $2 : $1 }
    | {- empty -}       { [] }

BlockStatement :: { BlockStatement }
BlockStatement
    : VariableDeclaration   { BlockVD $1 }
    | Statement         { Statement $1 }

Statement :: { Statement }
Statement
    : Block     { SubBlock $1 }
    | IfStatement   { IfStatement $1 }
    | WhileStatement    { WhileStatement $1 }
    | ForStatement      { ForStatement $1 }
    | ReturnStatement   { Return $1 }
    | break ";"            { Break }
    | continue ";"          { Continue }
    | Expression ";"        { ExpressionStatement $1 }

IfStatement :: { If }
IfStatement
    : if ParExperssion Statement ElseStatement      { If $2 $3 $4 }

ElseStatement :: { Maybe Statement }
ElseStatement
    : else Statement    { Just $2 }
    | {- empty -}       { Nothing }

WhileStatement :: { While }
WhileStatement
    : while ParExperssion Statement     { While $2 $3 }

ParExperssion :: { Expression }
ParExperssion
    : "(" Expression ")"    { $2 }

ForStatement :: { For }
ForStatement
    : for "(" ForInit ForExpression ForIncrement ")" Statement      { For $3 $4 $5 $7 }

ForInit :: { ForInit }
ForInit
    : VariableDeclaration   { ForInitVD $1 }
    | ExpressionList ";"    { ForInitEL $1 }

ForExpression :: { Expression }
ForExpression
    : Expression ";"        { $1 }

ForIncrement :: { [Expression] }
ForIncrement
    : ExpressionList    { $1 }

ReturnStatement :: { Maybe Expression }
ReturnStatement
    : return Expression ";"     { Just $2 }
    | return ";"        { Nothing }

Expression :: { Expression }
Expression
    : QualifiedName "=" Expression { Assign $1 $3 }
    | Expression "||" Expression { Or $1 $3 }
    | Expression "&&" Expression { And $1 $3 }
    | Expression "==" Expression { Equal $1 $3 }
    | Expression "!=" Expression { Ne $1 $3 }
    | Expression "<" Expression { Lt $1 $3 }
    | Expression ">" Expression { Gt $1 $3 }
    | Expression "<=" Expression { Le $1 $3 }
    | Expression ">=" Expression { Ge $1 $3 }
    | Expression "+" Expression { Plus $1 $3 }
    | Expression "-" Expression { Minus $1 $3 }
    | Expression "*" Expression { Mul $1 $3 }
    | Expression "/" Expression { Div $1 $3 }
    | Expression "%" Expression { Mod $1 $3 }
    | "+" Expression %prec UNARY { Pos $2 }
    | "-" Expression %prec UNARY { Neg $2 }
    | "!" Expression { Not $2 }
    | "++" QualifiedName { PreInc $2 }
    | "--" QualifiedName { PreDec $2 }
    | QualifiedName "++" %prec POSTFIX { PostInc $1 }
    | QualifiedName "--" %prec POSTFIX { PostDec $1 }
    | QualifiedName { QN $1 }
    | ParExperssion { $1 }
    | literal { Literal $1 }
    | null { Null }

ExpressionList :: { [Expression] }
ExpressionList
    : ExpressionRevList { reverse $1 }

ExpressionRevList :: { [Expression] }
ExpressionRevList
    : ExpressionRevList "," Expression { $3 : $1 }
    | Expression { [$1] }

QualifiedName :: { QualifiedName }
QualifiedName
    : QualifiedName "." identifier  { FieldAccess $1 $3 }
    | QualifiedName "." identifier "(" ExpressionList ")"  { MethodCall $1 $3 $5 }
    | identifier "(" ExpressionList ")" { MethodCall This $1 $3 }
    | identifier { FieldOrVar $1 }
    | new ObjectType  "(" ExpressionList ")"  { New $2 $4 }
    | this { This }

Type :: { Type }
Type
    : PrimaryType { PrimaryType $1 }
    | ObjectType { ObjectType $1 }

ObjectType :: { ObjectType }
ObjectType
    : identifier { CustomType $1 }

PrimaryType :: { PrimaryType }
PrimaryType
    : boolean { TBoolean }
    | byte { TByte }
    | short { TShort }
    | int { TInt }
    | long { TLong }
    | float { TFloat }
    | double { TDouble }

{
parseError :: [Token] -> a
parseError ((Token t (line :!: column)) : _) = error $ "unexpected token " ++ (show t) ++ " at position " ++ (show line) ++ ":" ++ (show column)
parseError [] = error "unexpected end of file"
}
