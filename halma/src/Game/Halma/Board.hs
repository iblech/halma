{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}

module Game.Halma.Board
  ( HalmaGridSize (..), HalmaGrid (..)
  , sideLength, numberOfFields
  , HalmaDirection (..)
  , oppositeDirection
  , leftOf
  , rowsInDirection
  , corner
  , Team
  , startCorner, endCorner
  , startFields, endFields
  , Piece (..)
  , HalmaBoard, getGrid, toMap, fromMap
  , lookupHalmaBoard
  , Move (..)
  , movePiece
  , initialBoard
  ) where

import Control.Monad (unless)
import Data.Aeson ((.=), (.:))
import Data.List (sort)
import Data.Maybe (fromJust)
import Data.Word (Word8)
import GHC.Generics (Generic)
import qualified Data.Aeson as A
import qualified Data.Aeson.Types as A
import qualified Data.Map.Strict as M
import qualified Math.Geometry.Grid as Grid
import qualified Math.Geometry.GridInternal as Grid
import qualified Math.Geometry.Grid.Hexagonal as HexGrid
import qualified Math.Geometry.Grid.HexagonalInternal as HexGrid

data HalmaGridSize = S | L

data HalmaGrid :: HalmaGridSize -> * where
  SmallGrid :: HalmaGrid 'S
  LargeGrid :: HalmaGrid 'L

instance Eq (HalmaGrid size) where
  _ == _ = True

instance Ord (HalmaGrid size) where
  _ `compare` _ = EQ

instance Show (HalmaGrid size) where
  show SmallGrid = "SmallGrid"
  show LargeGrid = "LargeGrid"

instance A.ToJSON (HalmaGrid size) where
  toJSON grid =
    case grid of
      SmallGrid -> "SmallGrid"
      LargeGrid -> "LargeGrid"

instance A.FromJSON (HalmaGrid 'S) where
  parseJSON =
    A.withText "HalmaGrid 'S" $ \text ->
      if text == "SmallGrid" then
        pure SmallGrid
      else
        fail "expected the string 'SmallGrid'"

instance A.FromJSON (HalmaGrid 'L) where
  parseJSON =
    A.withText "HalmaGrid 'L" $ \text ->
      if text == "LargeGrid" then
        pure LargeGrid
      else
        fail "expected the string 'LargeGrid'"

-- | Numbers of fields on each straight edge of a star-shaped halma board of the
-- given size.
sideLength :: HalmaGrid size -> Int
sideLength grid =
  case grid of
    SmallGrid -> 5
    LargeGrid -> 6

-- | Total number of fields on a halma board of the given size.
numberOfFields :: HalmaGrid size -> Int
numberOfFields grid =
  case grid of
    SmallGrid -> 121
    LargeGrid -> 181

-- | The six corners of a star-shaped halma board.
data HalmaDirection
  = North
  | Northeast
  | Southeast
  | South
  | Southwest
  | Northwest
  deriving (Eq, Show, Read, Ord, Bounded, Enum, Generic)

instance A.ToJSON HalmaDirection where
  toJSON dir =
    case dir of
      North -> "N"
      Northeast -> "NE"
      Southeast -> "SE"
      South -> "S"
      Southwest -> "SW"
      Northwest -> "NW"

instance A.FromJSON HalmaDirection where
  parseJSON =
    A.withText "HalmaDirection" $ \text ->
      case text of
        "N"  -> pure North
        "NE" -> pure Northeast
        "SE" -> pure Southeast
        "S"  -> pure South
        "SW" -> pure Southwest
        "NW" -> pure Northwest
        _    -> fail "expected a Halma direction (one of N, NE, SE, S, SW, NW)"

oppositeDirection :: HalmaDirection -> HalmaDirection
oppositeDirection dir =
  case dir of
    North -> South
    South -> North
    Northeast -> Southwest
    Southwest -> Northeast
    Northwest -> Southeast
    Southeast -> Northwest

leftOf :: HalmaDirection -> HalmaDirection
leftOf dir =
  case dir of
    North -> Northwest
    Northwest -> Southwest
    Southwest -> South
    South -> Southeast
    Southeast -> Northeast
    Northeast -> North

getDirs :: HalmaDirection -> (HexGrid.HexDirection, HexGrid.HexDirection)
getDirs dir =
  case dir of
    North -> (HexGrid.Northwest, HexGrid.Northeast)
    South -> (HexGrid.Southwest, HexGrid.Southeast)
    Northeast -> (HexGrid.Northeast, HexGrid.East)
    Northwest -> (HexGrid.Northwest, HexGrid.West)
    Southeast -> (HexGrid.Southeast, HexGrid.East)
    Southwest -> (HexGrid.Southwest, HexGrid.West)

neighbour' :: HexGrid.HexDirection -> (Int, Int) -> (Int, Int)
neighbour' dir = fromJust . flip (Grid.neighbour HexGrid.UnboundedHexGrid) dir

-- | From the point of view of the given corner: On which row lies the given
-- field? The row through the center is row zero, rows nearer to the corner have
-- positive, rows nearer to the opposite corner negative numbers.
rowsInDirection :: HalmaDirection -> (Int, Int) -> Int
rowsInDirection dir =
  cramerPlus (neighbour' dir1 (0,0)) (neighbour' dir2 (0,0))
  where
    (dir1, dir2) = getDirs dir
    cramerPlus (a,b) (c,d) (x,y) =
      -- Computes (e+f) where (e,f) is the solution of M*(e,f) = (x,y)
      -- where M is the matrix with column vectors (a,b) and (c,d).
      -- Precondition: det(M) = 1/det(M), i.e. det(M) `elem` [-1,1].
      let det = a*d - b*c
      in det * (x*(d-b) + y*(a-c))
        
-- | The corner corresponding to a direction on a star-shaped board of the
-- given size.
corner :: HalmaGrid size -> HalmaDirection -> (Int, Int)
corner halmaGrid direction = (sl*x, sl*y)
  where
    (d1, d2) = getDirs direction
    sl = sideLength halmaGrid - 1
    (x, y) = neighbour' d1 $ neighbour' d2 (0, 0)

instance Grid.Grid (HalmaGrid size) where
  type Index (HalmaGrid size) = (Int, Int)
  type Direction (HalmaGrid size) = HexGrid.HexDirection
  indices halmaGrid = filter (Grid.contains halmaGrid) roughBoard
    where
      sl = sideLength halmaGrid - 1
      roughBoard = Grid.indices (HexGrid.hexHexGrid (2*sl + 1))
  neighbours = Grid.neighboursBasedOn HexGrid.UnboundedHexGrid
  distance = Grid.distanceBasedOn HexGrid.UnboundedHexGrid
  directionTo = Grid.directionToBasedOn HexGrid.UnboundedHexGrid
  contains halmaGrid (x, y) = atLeastTwo (test x) (test y) (test z)
    where
      z = x + y
      test i = abs i <= sl
      sl = sideLength halmaGrid - 1
      atLeastTwo True True _ = True
      atLeastTwo True False True = True
      atLeastTwo False True True = True
      atLeastTwo _ _ _ = False

instance Grid.FiniteGrid (HalmaGrid 'S) where
  type Size (HalmaGrid 'S) = ()
  size _ = ()
  maxPossibleDistance _ = 16

instance Grid.FiniteGrid (HalmaGrid 'L) where
  type Size (HalmaGrid 'L) = ()
  size _ = ()
  maxPossibleDistance _ = 20

instance Grid.BoundedGrid (HalmaGrid size) where
  tileSideCount _ = 6

-- | The corner where the team starts.
type Team = HalmaDirection

-- | The position of the corner field where a team starts.
startCorner :: HalmaGrid size -> Team -> (Int, Int)
startCorner = corner

-- | The position of the end zone corner of a team.
endCorner :: HalmaGrid size -> Team -> (Int, Int)
endCorner halmaGrid = corner halmaGrid . oppositeDirection

-- | The start positions of a team's pieces.
startFields :: HalmaGrid size -> Team -> [(Int, Int)]
startFields halmaGrid team = filter ((<= 4) . dist) (Grid.indices halmaGrid)
  where dist = Grid.distance halmaGrid (startCorner halmaGrid team)

-- | The end zone of the given team.
endFields :: HalmaGrid size -> Team -> [(Int, Int)]
endFields halmaGrid = startFields halmaGrid . oppositeDirection

-- | Halma gaming piece
data Piece
  = Piece
  { pieceTeam :: Team  -- ^ player 
  , pieceNumber :: Word8 -- ^ number between 1 and 15
  } deriving (Show, Eq, Ord)

instance A.ToJSON Piece where
  toJSON piece =
    A.object
      [ "team" .= A.toJSON (pieceTeam piece)
      , "number" .= A.toJSON (pieceNumber piece)
      ]

instance A.FromJSON Piece where
  parseJSON =
    A.withObject "Piece" $ \o -> do
      team <- o .: "team"
      number <- o .: "number"
      unless (1 <= number && number <= 15) $
        fail "pieces must have a number between 1 and 15!"
      pure $ Piece { pieceTeam = team, pieceNumber = number }
          

-- | Map from board positions to the team occupying that position.
data HalmaBoard size =
  HalmaBoard
  { getGrid :: HalmaGrid size
  , toMap :: M.Map (Int, Int) Piece
  } deriving (Eq)

instance Show (HalmaBoard size) where
  show (HalmaBoard halmaGrid m) =
    "fromMap " ++ show halmaGrid ++ " (" ++ show m ++ ")"

instance A.ToJSON (HalmaBoard size) where
  toJSON board =
    A.object
      [ "grid" .= A.toJSON (getGrid board)
      , "occupied_fields" .= map fieldToJSON (M.assocs (toMap board))
      ]
    where
      fieldToJSON ((x, y), piece) =
        A.object
          [ "x" .= x
          , "y" .= y
          , "piece" .= A.toJSON piece
          ]

parseHalmaBoardFromJSON
  :: A.FromJSON (HalmaGrid size)
  => A.Value
  -> A.Parser (HalmaBoard size)
parseHalmaBoardFromJSON =
  A.withObject "HalmaGrid size" $ \o -> do
    grid <- o .: "grid"
    fieldVals <- o .: "occupied_fields"
    fieldsMap <- M.fromList <$> mapM parseFieldFromJSON fieldVals
    case fromMap grid fieldsMap of
      Just board -> pure board
      Nothing ->
        fail "the JSON describing the occupied fields violates some invariant!"
  where
    parseFieldFromJSON =
      A.withObject "field" $ \o -> do
        x <- o .: "x"
        y <- o .: "y"
        piece <- o .: "piece"
        pure ((x, y), piece)

instance  A.FromJSON (HalmaBoard 'S) where
  parseJSON = parseHalmaBoardFromJSON

instance  A.FromJSON (HalmaBoard 'L) where
  parseJSON = parseHalmaBoardFromJSON

-- | Construct halma boards. Satisfies
-- @fromMap (getGrid board) (toMap board) = Just board@.
fromMap
  :: HalmaGrid size
  -> M.Map (Grid.Index (HalmaGrid size)) Piece
  -> Maybe (HalmaBoard size)
fromMap halmaGrid m =
  if invariantsHold then
    Just (HalmaBoard halmaGrid m)
  else
    Nothing
  where
    invariantsHold = indicesCorrect && rightTeamPieces
    list = M.toList m
    indicesCorrect = all (Grid.contains halmaGrid . fst) list
    allTeams = [minBound..maxBound]
    rightTeamPieces = all rightNumberOfTeamPieces allTeams
    rightNumberOfTeamPieces team =
      let teamPieces = filter ((== team) . pieceTeam) (map snd list)
      in null teamPieces || sort teamPieces == map (Piece team) [1..15]

-- | Lookup whether a position on the board is occupied, and 
lookupHalmaBoard :: (Int, Int) -> HalmaBoard size -> Maybe Piece
lookupHalmaBoard p = M.lookup p . toMap

-- | A move of piece on a (Halma) board.
data Move
  = Move
  { moveFrom :: (Int, Int) -- ^ start position
  , moveTo :: (Int, Int) -- ^ end position, must be different from start position
  } deriving (Show, Eq)

instance A.ToJSON Move where
  toJSON move =
    A.object
      [ "from" .= coordsToJSON (moveFrom move)
      , "to"   .= coordsToJSON (moveTo move)
      ]
    where
      coordsToJSON (x, y) = A.object [ "x" .= x, "y" .= y ]

instance A.FromJSON Move where
  parseJSON =
    A.withObject "Move" $ \o -> do
      from <- parseCoordsFromJSON =<< o .: "from"
      to <- parseCoordsFromJSON =<< o .: "to"
      pure $ Move { moveFrom = from, moveTo = to }
    where
      parseCoordsFromJSON =
        A.withObject "(Int, Int)" $ \o ->
          (,) <$> o .: "x" <*> o .: "y"

-- | Move a piece on the halma board. This function does not check whether the
-- move is valid according to the Halma rules.
movePiece
  :: Move
  -> HalmaBoard size
  -> Either String (HalmaBoard size)
movePiece (Move { moveFrom = startPos, moveTo = endPos }) (HalmaBoard halmaGrid m) =
  case M.lookup startPos m of
    Nothing -> Left "cannot make move: start position is empty"
    Just piece ->
      case M.lookup endPos m of
        Just otherPiece ->
          Left $
            "cannot make move: end position is occupied by team " ++
            show (pieceTeam otherPiece)
        Nothing ->
          let m' = M.insert endPos piece (M.delete startPos m)
          in Right (HalmaBoard halmaGrid m')

initialBoard :: HalmaGrid size -> (Team -> Bool) -> HalmaBoard size
initialBoard halmaGrid chosenTeams = HalmaBoard halmaGrid (M.fromList lineUps)
  where
    allTeams = [minBound..maxBound]
    lineUps = concatMap lineUp allTeams
    mkPiece team number position =
      (position, Piece { pieceTeam = team, pieceNumber = number })
    lineUp team =
      if chosenTeams team
      then zipWith (mkPiece team) [1..15] (startFields halmaGrid team)
      else []