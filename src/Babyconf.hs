{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections     #-}

module Babyconf (parseConfFile, Protocol(..), Babyconf(..), Source(..), Watch(..), Action(..), Destinations, Destination(..)) where

import           Control.Applicative        (empty, (<|>))
import           Control.Monad              (unless, when)
import qualified Data.ByteString.Lazy       as BL
import qualified Data.ByteString.Lazy.UTF8  as BU
import           Data.Foldable              (fold)
import           Data.List                  (intercalate)
import           Data.Map.Strict            (Map)
import qualified Data.Map.Strict            as Map
import qualified Data.Set                   as Set
import           Data.String                (fromString)
import           Data.Text                  (Text, pack, unpack)
import           Data.Void                  (Void)
import           Network.MQTT.Topic
import           Text.Megaparsec            (Parsec, between, eof, noneOf, option, parse, sepBy, some, try)
import           Text.Megaparsec.Char       (alphaNumChar, hspace1, space, space1)
import qualified Text.Megaparsec.Char.Lexer as L
import           Text.Megaparsec.Error      (errorBundlePretty)

import           Network.URI

type Parser = Parsec Void Text

type Destinations = Map Text Destination

data Babyconf = Babyconf Destinations [Source] deriving(Show, Eq)

instance Semigroup Babyconf where
  Babyconf d1 s1 <> Babyconf d2 s2 = Babyconf (d1 <> d2) (s1 <> s2)

instance Monoid Babyconf where mempty = Babyconf mempty mempty

data Protocol = MQTT311 | MQTT5 deriving (Show, Eq)

data Destination = Pushover Text Text
                 | PagerDuty Text
                 deriving (Show, Eq)

data Source = MQTTSource (URI, Protocol, Maybe Topic, Maybe BL.ByteString) [Watch Filter]
            | InfluxSource URI [Watch Text]
  deriving(Show, Eq)

data Action = ActAlert [Text]
            | ActSet Topic BL.ByteString Bool
            | ActDelete
            deriving (Show, Eq)

data Watch t = Watch t Int Action deriving(Show, Eq)

comment :: Parser ()
comment = L.skipLineComment "#" <* space

sc :: Parser ()
sc = L.space space1 comment empty

lexeme :: Parser a -> Parser a
lexeme = L.lexeme (L.space hspace1 comment empty)

parseBabyconf :: Parser Babyconf
parseBabyconf = do
  c@(Babyconf ds ws) <- fold <$> some parseSection <* eof
  let wanted = Set.fromList (foldMap watches ws)
      missing = wanted `Set.difference` Map.keysSet ds
  unless (null missing) $ fail ("unknown alert destinations: "
                                <> intercalate ", " (fmap unpack (Set.toList missing)))
  pure c

  where
    watches (MQTTSource _ ws)   = watchers ws
    watches (InfluxSource _ ws) = watchers ws

    watchers = foldMap w
      where
        w (Watch _ _ (ActAlert l)) = l
        w _                        = []

parseSection :: Parser Babyconf
parseSection = parseDest <|> parseSource

parseSource :: Parser Babyconf
parseSource = L.nonIndented sc src

  where
    src = Babyconf mempty . (:[]) <$> (try mqttSrc <|> influxSrc)

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

parseDest :: Parser Babyconf
parseDest = Babyconf <$> (pushover <|> pagerduty) <*> pure mempty
  where
    pushover = do
      (k, m) <- itemList hdr user
      pure $ Map.fromList [(u, Pushover k v) | (u, v) <- m]
        where
          hdr = pack <$> ("dest pushover " *> some (noneOf ['\n']))
          user = (,) <$> lexeme word <*> word

    pagerduty = do
      (k, m) <- itemList hdr user
      pure $ Map.fromList [(u, PagerDuty k) | u <- m]
        where
          hdr = pack <$> ("dest pagerduty " *> some (noneOf ['\n']))
          user = lexeme word

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
