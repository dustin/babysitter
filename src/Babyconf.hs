{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections     #-}

module Babyconf (parseConfFile, Babyconf(..), Source(..), Watch(..), PushoverConf(..)) where

import           Control.Applicative        (empty, (<|>))
import qualified Data.ByteString.Lazy       as BL
import qualified Data.ByteString.Lazy.Char8 as BC
import           Data.Map.Strict            (Map)
import qualified Data.Map.Strict            as Map
import           Data.Text                  (Text, pack)
import           Data.Void                  (Void)
import           Text.Megaparsec            (Parsec, between, eof, noneOf,
                                             option, parse, sepBy, some, try)
import           Text.Megaparsec.Char       (alphaNumChar, space, space1)
import qualified Text.Megaparsec.Char.Lexer as L
import           Text.Megaparsec.Error      (errorBundlePretty)

import           Network.URI

type Parser = Parsec Void Text

data Babyconf = Babyconf PushoverConf [Source] deriving(Show)

data Source = Source (URI, (Maybe Text), (Maybe BL.ByteString)) [Watch] deriving(Show)

data Watch = Watch Text Int [Text] deriving(Show)

data PushoverConf = PushoverConf Text (Map Text Text) deriving(Show)

parseBabyconf :: Parser Babyconf
parseBabyconf = do
  pc <- parsePushoverConf <* space
  srcs <- some parseSource <* eof
  pure $ Babyconf pc srcs

parseSource :: Parser Source
parseSource = do
  (u, ws) <- itemList src watch
  pure $ Source u ws

  where
    src = do
      _ <- "src" *> space
      ustr <- some (noneOf ['\n', ' '])
      let (Just u) = parseURI ustr
      (lwtt,lwtm) <- option (Nothing, Nothing) (try plwt)
      pure (u, lwtt, lwtm)

    watch = do
      t <- "watch" *> space *> qstr <* space
      tm <- time <* space <* "->" <* space
      u <- "alert" *> ((space *> word) `sepBy` ",")

      pure $ Watch (pack t) tm u

    qstr = between "\"" "\"" (some $ noneOf ['"'])

    time = do
      b <- L.decimal
      m <- seconds <$ "s" <|> minutes <$ "m" <|> hours <$ "h" <|> pure seconds
      pure (m b)

    plwt :: Parser (Maybe Text, Maybe BL.ByteString)
    plwt = do
      topic <- space *> qstr
      msg <- space *> qstr
      pure (Just (pack topic), Just (BC.pack msg))

    millis = (* 1000)
    seconds = millis . (* 1000)
    minutes = seconds . (* 60)
    hours = minutes . (* 60)

parsePushoverConf :: Parser PushoverConf
parsePushoverConf = do
  (p, us) <- itemList pushover user
  pure $ PushoverConf p (Map.fromList us)

  where
    pushover :: Parser Text
    pushover = do
      t <- "dest pushover " *> (some $ noneOf ['\n'])
      pure (pack t)

    user :: Parser (Text,Text)
    user = (,) <$> word <* space <*> word

word :: Parser Text
word = pack <$> some alphaNumChar

lineComment :: Parser ()
lineComment = L.skipLineComment "#"

itemList :: (Parser a) -> (Parser b) ->  Parser (a, [b])
itemList pa pb = L.nonIndented scn (L.indentBlock scn p)
  where
    scn = L.space space1 lineComment empty
    p = do
      header <- pa
      return (L.IndentMany Nothing (return . (header, )) pb)

parseFile :: Parser a -> String -> IO a
parseFile f s = do
  c <- pack <$> readFile s
  case parse f s c of
    (Left x)  -> fail (errorBundlePretty x)
    (Right v) -> pure v

parseConfFile :: String -> IO Babyconf
parseConfFile = parseFile parseBabyconf
