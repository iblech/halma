{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}

module Main where

import Game.Halma.Board
import Game.Halma.Configuration
import Game.Halma.State (HalmaState (..))
import Game.Halma.TelegramBot.BotM
import Game.Halma.TelegramBot.Cmd
import Game.Halma.TelegramBot.DrawBoard
import Game.Halma.TelegramBot.Move
import Game.Halma.TelegramBot.Types
import Game.TurnCounter

import Data.Foldable (toList)
import Data.Maybe (catMaybes)
import Data.Monoid ((<>))
import Control.Monad (unless)
import Control.Monad.IO.Class (MonadIO (..))
import Control.Monad.State.Class (MonadState (..), gets, modify)
import Servant.Common.Req (ServantError)
import System.Environment (getArgs)
import System.IO (hPutStrLn, stderr)
import qualified Data.Text as T
import qualified Web.Telegram.API.Bot as TG

main :: IO ()
main =
  getArgs >>= \case
    [tokenStr, chatId] -> do
      let token = TG.Token (ensureIsPrefixOf "bot" (T.pack tokenStr))
      evalBotM halmaBot (initialBotState (T.pack chatId) token)
    _ -> do
      hPutStrLn stderr "Usage: ./halma-bot telegram-token chat-id"

ensureIsPrefixOf :: T.Text -> T.Text -> T.Text
ensureIsPrefixOf prefix str =
  if prefix `T.isPrefixOf` str then str else prefix <> str

mkButton :: T.Text -> TG.KeyboardButton
mkButton text =
  TG.KeyboardButton
    { TG.kb_text = text
    , TG.kb_request_contact = Nothing
    , TG.kb_request_location = Nothing
    }

mkKeyboard :: [[T.Text]] -> TG.ReplyKeyboard
mkKeyboard buttonLabels =
  TG.ReplyKeyboardMarkup
    { TG.reply_keyboard = fmap mkButton <$> buttonLabels
    , TG.reply_resize_keyboard = Just True
    , TG.reply_one_time_keyboard = Just True
    , TG.reply_selective = Just False
    }

textMsgWithKeyboard :: T.Text -> TG.ReplyKeyboard -> Msg
textMsgWithKeyboard text keyboard chatId =
  (TG.sendMessageRequest chatId text)
  { TG.message_reply_markup = Just keyboard }

getUpdates :: BotM (Either ServantError [TG.Update])
getUpdates = do
  nid <- gets bsNextId
  let
    limit = 100
    timeout = 10
    updateReq =
      \token -> TG.getUpdates token (Just nid) (Just limit) (Just timeout)
  runReq updateReq >>= \case
    Left err -> return (Left err)
    Right (TG.UpdatesResponse updates) -> do
      unless (null updates) $ do
        let nid' = 1 + maximum (map TG.update_id updates)
        modify (\s -> s { bsNextId = nid' })
      return (Right updates)
  
sendCurrentBoard :: HalmaState size Player -> BotM ()
sendCurrentBoard halmaState =
  withRenderedBoardInPngFile (hsBoard halmaState) $ \path -> do
    chatId <- gets bsChatId
    let
      fileUpload = TG.localFileUpload path
      photoReq = TG.uploadPhotoRequest chatId fileUpload
    logErrors $ runReq $ \token -> TG.uploadPhoto token photoReq

welcomeMsg :: Msg
welcomeMsg chatId =
  let
    text =
      "Greetings from HalmaBot! This is an open-source bot written in " <>
      "Haskell by Tim Baumann <tim@timbaumann.info>. " <>
      "The source code is available at https://github.com/timjb/halma."
  in
    (TG.sendMessageRequest chatId text)
    { TG.message_disable_web_page_preview = Just True }

helpMsg :: Msg
helpMsg =
  textMsg $
    "You can control HalmaBot by sending these commands:\n" <>
    "/newmatch — starts a new match between two or three players\n" <>
    "/newround — start a new game round\n" <>
    "/help — display this message\n\n" <>
    "Here's how move commands are structured:\n" <>
    "First there comes a letter in the range A-O (the piece you want to move), then the number of the row you want to move the piece to. If there are multiple possible target positions on the row, you will be asked which one you mean.\n" <>
    "For example: a11 tells HalmaBot to move the piece label 'a' to number 11."

handleCommand :: CmdCall -> BotM (Maybe (BotM ()))
handleCommand cmdCall =
  case cmdCall of
    CmdCall { cmdCallName = "help" } -> do
      sendMsg helpMsg
      pure Nothing
    CmdCall { cmdCallName = "start" } ->
      pure $ Just (sendMsg welcomeMsg)
    CmdCall { cmdCallName = "newmatch" } ->
      pure $ Just $ modify $ \botState ->
        botState { bsMatchState = GatheringPlayers NoPlayers }
    CmdCall { cmdCallName = "newround" } ->
      pure $ Just $ sendMsg $ textMsg "todo: newgame"
    _ -> pure Nothing

handleMoveCmd
  :: Match size
  -> HalmaState size Player
  -> MoveCmd
  -> TG.Message
  -> BotM (Maybe (BotM ()))
handleMoveCmd match game moveCmd fullMsg = do
  liftIO $ putStrLn $ T.unpack $ showMoveCmd moveCmd
  case TG.from fullMsg of
    Nothing -> do
      sendMsg $ textMsg $
        "can't identify sender of move command " <> showMoveCmd moveCmd <> "!"
      pure Nothing
    Just sender -> do
      let
        (team, player) = currentPlayer (hsTurnCounter game)
        checkResult =
          checkMoveCmd (hsRuleOptions game) (hsBoard game) team moveCmd
      case checkResult of
        _ | player /= TelegramPlayer sender -> do
          sendMsg $ textMsg $
            "Hey " <> showUser sender <> ", it's not your turn, it's " <>
            showPlayer player <> "'s!"
          pure Nothing
        MoveImpossible reason -> do
          sendMsg $ textMsg $
            "This move is not possible: " <> T.pack reason
          pure Nothing
        MoveSuggestions suggestions -> do
          let
            text =
              showUser sender <> ", the move command you sent is ambiguous. " <>
              "Please send another move command or choose one in the " <>
              "following list."
            suggestionToButton (modifier, _move) =
              let moveCmd' = moveCmd { moveTargetModifier = Just modifier }
              in [showMoveCmd moveCmd']
            keyboard = mkKeyboard (suggestionToButton <$> toList suggestions)
          sendMsg $ textMsgWithKeyboard text keyboard
          pure Nothing
        MoveFoundUnique move ->
          case movePiece move (hsBoard game) of
            Left err -> do
              printError err
              pure Nothing
            Right board' -> do
              let
                game' =
                  game
                    { hsBoard = board'
                    , hsTurnCounter = nextTurn (hsTurnCounter game)
                    }
                match' = match { matchCurrentGame = Just game' }
              pure $ Just $ do
                modify $ \botState ->
                  botState { bsMatchState = MatchRunning match' }

handleTextMsg
  :: T.Text
  -> TG.Message
  -> BotM (Maybe (BotM ()))
handleTextMsg text fullMsg = do
  matchState <- gets bsMatchState
  case (matchState, text) of
    (_, parseCmdCall -> Just cmdCall) ->
      handleCommand cmdCall
    ( MatchRunning (match@(Match { matchCurrentGame = Just game })), parseMoveCmd -> Right moveCmd) ->
      handleMoveCmd match game moveCmd fullMsg
    (GatheringPlayers players, "me") ->
      pure $ Just (addTelegramPlayer players)
    (GatheringPlayers players, "yes, me") ->
      pure $ Just (addTelegramPlayer players)
    (GatheringPlayers players, "an AI") ->
      pure $ Just (addAIPlayer players)
    (GatheringPlayers players, "yes, an AI") ->
      pure $ Just (addAIPlayer players)
    (GatheringPlayers (EnoughPlayers config), "no") ->
      pure $ Just (startMatch config)
    _ -> pure Nothing
  where
    addPlayer :: Player -> PlayersSoFar Player -> BotM ()
    addPlayer new playersSoFar = do
      let
        playersSoFar' =
          case playersSoFar of
            NoPlayers ->
              OnePlayer new
            OnePlayer a ->
              EnoughPlayers (Configuration SmallGrid (TwoPlayers a new))
            EnoughPlayers (Configuration grid players) ->
              case players of
                TwoPlayers a b ->
                  EnoughPlayers $ Configuration grid (ThreePlayers a b new)
                ThreePlayers a b c ->
                  EnoughPlayers $ Configuration LargeGrid (FourPlayers a b c new)
                FourPlayers a b c d ->
                  EnoughPlayers $ Configuration LargeGrid (FivePlayers a b c d new)
                FivePlayers a b c d e ->
                  EnoughPlayers $ Configuration LargeGrid (SixPlayers a b c d e new)
                SixPlayers {} ->
                  EnoughPlayers $ Configuration grid players
      botState <- get
      case playersSoFar' of
        EnoughPlayers config@(Configuration _grid (SixPlayers {})) ->
          put $ botState { bsMatchState = MatchRunning (newMatch config) }
        _ ->
          put $ botState { bsMatchState = GatheringPlayers playersSoFar' }
    addAIPlayer :: PlayersSoFar Player -> BotM ()
    addAIPlayer = addPlayer AIPlayer
    addTelegramPlayer :: PlayersSoFar Player -> BotM ()
    addTelegramPlayer players =
      case TG.from fullMsg of
        Nothing ->
          sendMsg $ textMsg "cannot add sender of last message as a player!"
        Just user ->
          addPlayer (TelegramPlayer user) players
    startMatch players =
      modify $ \botState ->
        botState { bsMatchState = MatchRunning (newMatch players) }

sendGatheringPlayers :: PlayersSoFar Player -> BotM ()
sendGatheringPlayers playersSoFar = 
  case playersSoFar of
    NoPlayers ->
      sendMsg $ textMsgWithKeyboard
        "Starting a new match! Who is the first player?"
        meKeyboard
    OnePlayer firstPlayer ->
      let
        text =
          "The first player is " <> showPlayer firstPlayer <> ".\n" <>
          "Who is the second player?"
      in
        sendMsg (textMsgWithKeyboard text meKeyboard)
    EnoughPlayers (Configuration _grid players) -> do
      (count, nextOrdinal) <-
        case players of
          TwoPlayers {}   -> pure ("two", "third")
          ThreePlayers {} -> pure ("three", "fourth")
          FourPlayers {}  -> pure ("four", "fifth")
          FivePlayers {}  -> pure ("five", "sixth")
          SixPlayers {} ->
            fail "unexpected state: gathering players although there are already six!"
      let
        text =
          "The first " <> count <> " players are " <>
          prettyList (map showPlayer (toList players)) <> ".\n" <>
          "Is there a " <> nextOrdinal <> " player?"
      sendMsg (textMsgWithKeyboard text anotherPlayerKeyboard)
  where
    prettyList :: [T.Text] -> T.Text
    prettyList xs =
      case xs of
        [] -> "<empty list>"
        [x] -> x
        _ -> T.intercalate ", " (init xs) <> " and " <> last xs
    meKeyboard = mkKeyboard [["me"], ["an AI"]]
    anotherPlayerKeyboard =
      mkKeyboard [["yes, me"], ["yes, an AI"], ["no"]]

mkAIMove :: HalmaState size Player -> BotM ()
mkAIMove _game = fail "mkAIMove not implemented yet!"

sendGameState :: HalmaState size Player -> BotM ()
sendGameState game = do
  sendCurrentBoard game
  let
    (_dir, player) = currentPlayer (hsTurnCounter game)
  case player of
    AIPlayer -> mkAIMove game
    TelegramPlayer user ->
      sendMsg $ textMsg $
        showUser user <> " it's your turn!"

sendMatchState :: BotM ()
sendMatchState = do
  matchState <- gets bsMatchState
  case matchState of
    NoMatch ->
      sendMsg $ textMsg $
        "Start a new Halma match with /newmatch"
    GatheringPlayers players ->
      sendGatheringPlayers players
    MatchRunning match ->
      case matchCurrentGame match of
        Nothing ->
          sendMsg $ textMsg $
            "Start a new round with /newround"
        Just game -> sendGameState game

halmaBot :: BotM ()
halmaBot = do
  sendMsg welcomeMsg
  mainLoop
  where
    mainLoop :: BotM ()
    mainLoop = do
      sendMatchState
      getUpdatesLoop
      mainLoop
    getUpdatesLoop =
      getUpdates >>= \case
        Left err -> do { printError err; getUpdatesLoop }
        Right updates -> do
          actions <- catMaybes <$> mapM handleUpdate updates
          if null actions then
            getUpdatesLoop
          else do
            sequence_ actions
            mainLoop
    handleUpdate update = do
      liftIO $ print update
      case update of
        TG.Update { TG.message = Just msg } -> handleMsg msg
        _ -> pure Nothing
    handleMsg msg =
      case msg of
        TG.Message { TG.text = Just txt } -> handleTextMsg txt msg
        _ -> pure Nothing
