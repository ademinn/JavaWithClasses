module Main where

import Parser
import Lexer

main :: IO ()
main = putStrLn . show . parse . alexScanTokens =<< getLine