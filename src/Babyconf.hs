{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections     #-}

module Babyconf (parseConfFile, Protocol(..), Babyconf(..), Source(..), Watch(..), Action(..), PushoverConf(..)) where

import           Control.Applicative        (empty, (<|>))
import           Control.Monad              (when)
import qualified Data.ByteString.Lazy       as BL
import qualified Data.ByteString.Lazy.UTF8  as BU
import           Data.Map.Strict            (Map)
import qualified Data.Map.Strict            as Map
import           Data.Text                  (Text, pack)
import           Data.Void                  (Void)
import           Text.Megaparsec            (Parsec, between, eof, noneOf, option, parse, sepBy, some, try)
import           Text.Megaparsec.Char       (alphaNumChar, space, space1)
import qualified Text.Megaparsec.Char.Lexer as L
import           Text.Megaparsec.Error      (errorBundlePretty)

import           Network.URI

type Parser = Parsec Void Text

data Babyconf = Babyconf PushoverConf [Source] deriving(Show, Eq)

data Protocol = MQTT311 | MQTT5 deriving (Show, Eq)

data Source = Source (URI, Protocol, Maybe Text, Maybe BL.ByteString) [Watch] deriving(Show, Eq)

data Action = ActAlert [Text]
            | ActSet Text BL.ByteString Bool
            | ActDelete
            deriving (Show, Eq)

data Watch = Watch Text Int Action deriving(Show, Eq)

data PushoverConf = PushoverConf Text (Map Text Text) deriving(Show, Eq)

sc :: Parser ()
sc = L.space space1 (L.skipLineComment "#" <* space) (L.skipBlockComment "/*" "*/")

lexeme :: Parser a -> Parser a
lexeme = L.lexeme sc

parseBabyconf :: Parser Babyconf
parseBabyconf = Babyconf <$> lexeme parsePushoverConf <*> some parseSource <* eof

-- Eat whitspace around a parser.
spacey :: Parser a -> Parser a
spacey f = space *> f <* space

parseSource :: Parser Source
parseSource = uncurry Source <$> itemList src watch

  where
    src = do
      u <- lexeme "src" *> auri
      pl <- option MQTT311 (try prot)
      (lwtt,lwtm) <- option (Nothing, Nothing) (try plwt)
      pure (u, pl, lwtt, lwtm)

    auri :: Parser URI
    auri = do
      ustr <- some (noneOf ['\n', ' '])
      u <- maybe (fail "bad url") pure (parseURI ustr)
      let sch = uriScheme u
      when (sch `notElem` ["mqtt:", "mqtts:", "influx:"]) $ fail ("invalid scheme: " <> show sch)
      pure u

    watch = Watch . pack <$> (lexeme "watch" *> lexeme qstr) <*> (lexeme time <* lexeme "->") <*> pact

    prot = spacey (MQTT5 <$ "mqtt5")

    qstr = between "\"" "\"" (some $ noneOf ['"'])
           <|> between "'" "'" (some $ noneOf ['\''])

    time = 0 <$ "instant" <|> do
      b <- L.decimal
      m <- seconds <$ "s" <|> minutes <$ "m" <|> hours <$ "h" <|> pure seconds
      pure (m b)

    plwt :: Parser (Maybe Text, Maybe BL.ByteString)
    plwt = do
      topic <- space *> qstr
      msg <- space *> qstr
      pure (Just (pack topic), Just (BU.fromString msg))

    pact :: Parser Action
    pact = try actAlert <|> actSet <|> actDelete
      where
        actAlert = do
          dests <- "alert" *> ((space *> word) `sepBy` ",")
          pure $ ActAlert dests
        actSet = do
          t <- "set" *> spacey qstr
          m <- spacey qstr
          r <- pbool
          pure $ ActSet (pack t) (BU.fromString m) r
        actDelete = ActDelete <$ "delete"

        pbool :: Parser Bool
        pbool = True <$ "True" <|> False <$ "False"

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
    pushover = pack <$> ("dest pushover " *> some (noneOf ['\n']))

    user :: Parser (Text,Text)
    user = (,) <$> lexeme word <*> word

word :: Parser Text
word = pack <$> some alphaNumChar

lineComment :: Parser ()
lineComment = L.skipLineComment "#"

itemList :: Parser a -> Parser b ->  Parser (a, [b])
itemList pa pb = L.nonIndented scn (L.indentBlock scn p)
  where
    scn = L.space space1 lineComment empty
    p = pa >>= \header -> pure (L.IndentMany Nothing (pure . (header, )) pb)

parseFile :: Parser a -> String -> IO a
parseFile f s = pack <$> readFile s >>= either (fail.errorBundlePretty) pure . parse f s

parseConfFile :: String -> IO Babyconf
parseConfFile = parseFile parseBabyconf
