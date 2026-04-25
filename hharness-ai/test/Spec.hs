module Main where

import Test.Hspec

import OpenAIProviderSpec

main :: IO ()
main = hspec $ do
  spec_toolCallToOpenAI
  spec_processSse
  spec_processCompletionDelta
