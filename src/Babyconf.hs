{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections     #-}

module Babyconf (parseConfFile, Protocol(..), Babyconf(..), Source(..), Watch(..), Action(..), PushoverConf(..)) where

import           Control.Applicative        (empty, (<|>))
import           Control.Monad              (when)
import qualified Data.ByteString.Lazy       as BL
import qualified Data.ByteString.Lazy.UTF8  as BU
import           Data.Map.Strict            (Map)
import qualified Data.Map.Strict            as Map
import           Data.String                (fromString)
import           Data.Text                  (Text, pack)
import           Data.Void                  (Void)
import           Network.MQTT.Topic
import           Text.Megaparsec            (Parsec, between, eof, noneOf, option, parse, sepBy, some, try)
import           Text.Megaparsec.Char       (alphaNumChar, hspace1, space, space1)
import qualified Text.Megaparsec.Char.Lexer as L
import           Text.Megaparsec.Error      (errorBundlePretty)

import           Network.URI

type Parser = Parsec Void Text

data Babyconf = Babyconf PushoverConf [Source] deriving(Show, Eq)

data Protocol = MQTT311 | MQTT5 deriving (Show, Eq)

data Source = MQTTSource (URI, Protocol, Maybe Topic, Maybe BL.ByteString) [Watch Filter]
            | InfluxSource URI [Watch Text]
  deriving(Show, Eq)


data Action = ActAlert [Text]
            | ActSet Topic BL.ByteString Bool
            | ActDelete
            deriving (Show, Eq)

data Watch t = Watch t Int Action deriving(Show, Eq)

data PushoverConf = PushoverConf Text (Map Text Text) deriving(Show, Eq)

comment :: Parser ()
comment = L.skipLineComment "#" <* space

sc :: Parser ()
sc = L.space space1 comment empty

lexeme :: Parser a -> Parser a
lexeme = L.lexeme (L.space hspace1 comment empty)

parseBabyconf :: Parser Babyconf
parseBabyconf = Babyconf <$> lexeme parsePushoverConf <*> some parseSource <* eof

parseSource :: Parser Source
parseSource = L.nonIndented sc src

  where
    src = try mqttSrc <|> influxSrc

    mqttSrc = uncurry MQTTSource <$> itemList ms (watch aFilter)
      where
        ms = do
          u <- lexeme "src" *> lexeme (auri ["mqtt:", "mqtts:"])
          pl <- option MQTT311 (try (lexeme prot))
          (lwtt,lwtm) <- option (Nothing, Nothing) plwt
          pure (u, pl, lwtt, lwtm)

    influxSrc = uncurry InfluxSource <$> itemList is (watch (fromString <$> qstr))
      where is = lexeme "src" *> auri ["influx:"]

    watch p = Watch <$> (lexeme "watch" *> lexeme p) <*> (lexeme time <* lexeme "->") <*> pact

    auri :: [String] -> Parser URI
    auri schemes = do
      ustr <- some (noneOf ['\n', ' '])
      u <- maybe (fail "bad url") pure (parseURI ustr)
      let sch = uriScheme u
      when (sch `notElem` schemes) $ fail ("invalid scheme: " <> show sch)
      pure u

    prot = MQTT5 <$ "mqtt5"

    qstr = between "\"" "\"" (some $ noneOf ['"'])
           <|> between "'" "'" (some $ noneOf ['\''])

    time = 0 <$ "instant" <|> do
      b <- L.decimal
      m <- seconds <$ "s" <|> minutes <$ "m" <|> hours <$ "h" <|> pure seconds
      pure (m b)

    plwt = (,) <$> (Just <$> lexeme aTopic) <*> (Just . BU.fromString <$> qstr)

    aTopic = qstr >>= maybe (fail "bad topic") pure . mkTopic . pack
    aFilter = qstr >>= maybe (fail "bad filter") pure . mkFilter . pack

    pact = actAlert <|> actSet <|> actDelete
      where
        actAlert = ActAlert <$> (lexeme "alert" *> (lexeme word `sepBy` ","))
        actSet = do
          f <- lexeme "set" *> lexeme aTopic
          m <- lexeme qstr
          ActSet f (BU.fromString m) <$> pbool
        actDelete = ActDelete <$ "delete"
        pbool = True <$ "True" <|> False <$ "False"

    millis = (* 1000)
    seconds = millis . (* 1000)
    minutes = seconds . (* 60)
    hours = minutes . (* 60)

parsePushoverConf :: Parser PushoverConf
parsePushoverConf = uncurry PushoverConf . fmap Map.fromList <$> itemList pushover user
  where
    pushover = pack <$> ("dest pushover " *> some (noneOf ['\n']))
    user = (,) <$> lexeme word <*> word

word :: Parser Text
word = pack <$> some alphaNumChar

itemList :: Parser a -> Parser b ->  Parser (a, [b])
itemList pa pb = L.nonIndented sc (L.indentBlock sc p)
  where
    p = pa >>= \header -> pure (L.IndentMany Nothing (pure . (header, )) pb)

parseFile :: Parser a -> String -> IO a
parseFile f s = readFile s >>= (either (fail . errorBundlePretty) pure . parse f s) . pack

parseConfFile :: String -> IO Babyconf
parseConfFile = parseFile parseBabyconf
