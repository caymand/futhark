module Futhark.Fmt.Monad
  ( Fmt,
    -- functions for building fmt
    nil,
    nest,
    stdNest,
    text,
    space,
    hardline,
    line,
    sep,
    brackets,
    braces,
    parens,
    (<|>),
    (<+>),
    (</>),
    (<:/>),
    hardIndent,
    indent,
    hardStdIndent,
    stdIndent,
    FmtM,
    popComments,
    runFormat,
    align,
    fmtCopyLoc,
    comment,
    sepArgs,
    localLayout,
    localLayoutList,
    sepDecs,
    fmtByLayout,
    addComments,
    sepComments,
    sepLineComments,
    sepLine,

    -- * Formatting styles
    commentStyle,
    constantStyle,
    keywordStyle,
    bindingStyle,
    infixStyle,
  )
where

import Control.Monad (liftM2)
import Control.Monad.Reader
  ( MonadReader (..),
    ReaderT (..),
  )
import Control.Monad.State
  ( MonadState (..),
    State,
    evalState,
    gets,
    modify,
  )
import Data.ByteString qualified as BS
import Data.List.NonEmpty qualified as NE
import Data.Loc (Loc (..), Located (..), locStart, posCoff, posLine)
import Data.Maybe (fromMaybe)
import Data.String
import Data.Text qualified as T
import Data.Text.Encoding qualified as T
import Language.Futhark.Parser.Monad (Comment (..))
import Prettyprinter qualified as P
import Prettyprinter.Render.Terminal
  ( AnsiStyle,
    Color (..),
    bold,
    color,
    colorDull,
    italicized,
  )

-- These are right associative since we want to evaluate the monadic
-- computation from left to right. Since the left most expression is
-- printed first and our monad is checking if a comment should be
-- printed.

infixr 6 <:/>

infixr 6 <+>

infixr 6 </>

infixr 4 <|>

type Fmt = FmtM (P.Doc AnsiStyle)

instance Semigroup Fmt where
  (<>) = liftM2 (<>)

instance Monoid Fmt where
  mempty = nil

instance IsString Fmt where
  fromString s = text style s'
    where
      s' = fromString s
      style =
        if s' `elem` keywords
          then keywordStyle
          else mempty
      keywords =
        [ "true",
          "false",
          "if",
          "then",
          "else",
          "def",
          "let",
          "loop",
          "in",
          "val",
          "for",
          "do",
          "with",
          "local",
          "open",
          "include",
          "import",
          "type",
          "entry",
          "module",
          "while",
          "assert",
          "match",
          "case"
        ]

commentStyle, keywordStyle, constantStyle, bindingStyle, infixStyle :: AnsiStyle
commentStyle = italicized
keywordStyle = color Magenta <> bold
constantStyle = color Green
bindingStyle = colorDull Blue
infixStyle = colorDull Cyan

-- | This function allows to inspect the layout of an expression @a@ and if it
-- is singleline line then use format @s@ and if it is multiline format @m@.
fmtByLayout ::
  (Located a) => a -> Fmt -> Fmt -> Fmt
fmtByLayout a s m =
  s
    <|> ( case lineLayout a of
            Just SingleLine -> s
            _any -> m
        )

-- | This function determines the Layout of @a@ and updates the monads
-- environment to format in the appropriate style. It determines this
-- by checking if the location of @a@ spans over two or more lines.
localLayout :: (Located a) => a -> FmtM b -> FmtM b
localLayout a = local (\lo -> fromMaybe lo $ lineLayout a)

-- | This function determines the Layout of @[a]@ and if it is singleline then it
-- updates the monads enviroment to format singleline style otherwise format using
-- multiline style. It determines this by checking if the locations of @[a]@
-- start and end at any different line number.
localLayoutList :: (Located a) => [a] -> FmtM b -> FmtM b
localLayoutList a m = do
  lo <- ask
  case lo of
    MultiLine -> local (const $ fromMaybe lo $ lineLayoutList a) m
    SingleLine -> m

-- | This function uses the location of @a@ and prepends comments if
-- the comments location is less than the location of @a@. It format
-- @b@ in accordance with if @a@ is singleline or multiline using
-- 'localLayout'. It currently does not handle trailing comment
-- perfectly. See tests/fmt/traillingComments*.fut.
addComments :: (Located a) => a -> Fmt -> Fmt
addComments a b = localLayout a $ do
  c <- fmtComments a
  f <- b
  pure $ c <> f

prependComments :: (a -> Loc) -> (a -> Fmt) -> a -> Fmt
prependComments floc fmt a = do
  fmcs <- fcs
  f <- fmt a
  pure $ fromMaybe mempty fmcs <> f
  where
    fcs = do
      s <- get
      case comments s of
        c : cs | floc a /= NoLoc && floc a > locOf c -> do
          put $ s {comments = cs}
          mcs <- fcs
          pre' <- pre
          pure $ Just $ pre' <> fmtNoLine c <> maybe mempty (P.line <>) mcs
        _any -> pure Nothing
    fmtNoLine = P.pretty . commentText
    pre = do
      lastO <- gets lastOutput
      case lastO of
        Nothing -> nil
        Just Line -> nil
        Just _ -> modify (\s -> s {lastOutput = Just Line}) >> hardline

-- | The internal state of the formatter monad 'FmtM'.
data FmtState = FmtState
  { -- | The comments that will be inserted, ordered by increasing order in regards to location.
    comments :: [Comment],
    -- | The original source file that is being formatted.
    file :: BS.ByteString,
    -- | Keeps track of what type the last output was.
    lastOutput :: !(Maybe LastOutput)
  }
  deriving (Show, Eq, Ord)

-- | A data type to describe the last output used during formatting.
data LastOutput = Line | Space | Text | Comm deriving (Show, Eq, Ord)

-- | A data type to describe the layout the formatter is using currently.
data Layout = MultiLine | SingleLine deriving (Show, Eq)

-- | The format monad used to keep track of comments and layout. It is a a
-- combincation of a reader and state monad. The comments and reading from the
-- input file are the state monads job to deal with. While the reader monad
-- deals with the propagating the current layout.
type FmtM a = ReaderT Layout (State FmtState) a

fmtComment :: Comment -> Fmt
fmtComment c = comment $ commentText c

fmtCommentList :: [Comment] -> Fmt
fmtCommentList [] = nil
fmtCommentList (c : cs) =
  fst $ foldl f (fmtComment c, locOf c) cs
  where
    f (acc, loc) c' =
      if consecutive loc (locOf c')
        then (acc <> fmtComment c', locOf c')
        else (acc <> hardline <> fmtComment c', locOf c')

hasComment :: (Located a) => a -> FmtM Bool
hasComment a =
  gets $ not . null . takeWhile relevant . comments
  where
    relevant c = locOf a /= NoLoc && locOf a > locOf c

-- | Prepends comments.
fmtComments :: (Located a) => a -> Fmt
fmtComments a = do
  (here, later) <- gets $ span relevant . comments
  if null here
    then pure mempty
    else do
      modify $ \s -> s {comments = later}
      fmtCommentList here
        <> if consecutive (locOf here) (locOf a) then nil else hardline
  where
    relevant c = locOf a /= NoLoc && locOf a > locOf c

-- | Determines the layout of @a@ by checking if it spans a single line or two
-- or more lines.
lineLayout :: (Located a) => a -> Maybe Layout
lineLayout a =
  case locOf a of
    Loc start end ->
      if posLine start == posLine end
        then Just SingleLine
        else Just MultiLine
    NoLoc -> Nothing -- error "Formatting term without location."

-- | Determines the layout of @[a]@ by checking if it spans a single line or two
-- or more lines.
lineLayoutList :: (Located a) => [a] -> Maybe Layout
lineLayoutList as =
  case concatMap auxiliary as of
    [] -> Nothing
    (t : ts) | any (/= t) ts -> Just MultiLine
    _ -> Just SingleLine
  where
    auxiliary a =
      case locOf a of
        Loc start end -> [posLine start, posLine end]
        NoLoc -> [] -- error "Formatting term without location"

-- | Retrieves the last comments from the monad and concatenates them together.
popComments :: Fmt
popComments = do
  cs <- gets comments
  modify (\s -> s {comments = []})
  lastO <- gets lastOutput
  case lastO of
    Nothing ->
      fmtCommentList cs -- Happens when file has only comments.
    _
      | not $ null cs -> hardline <> fmtCommentList cs
      | otherwise -> nil

-- | Using the location of @a@ get the segment of text in the original file to
-- create a @Fmt@.
fmtCopyLoc :: (Located a) => AnsiStyle -> a -> Fmt
fmtCopyLoc style a = do
  f <- gets file
  case locOf a of
    Loc sPos ePos ->
      let sOff = posCoff sPos
          eOff = posCoff ePos
       in case T.decodeUtf8' $ BS.take (eOff - sOff) $ BS.drop sOff f of
            Left err -> error $ show err
            Right lit -> text style lit
    NoLoc -> error "Formatting term without location"

-- | Given a formatter @FmtM a@, a sequence of comments ordered in increasing
-- order by location, and the original text files content. Run the formatter and
-- create @a@.
runFormat :: FmtM a -> [Comment] -> T.Text -> a
runFormat format cs file = evalState (runReaderT format e) s
  where
    s =
      FmtState
        { comments = cs,
          file = T.encodeUtf8 file,
          lastOutput = Nothing
        }
    e = MultiLine

-- | An empty input.
nil :: Fmt
nil = pure mempty

-- | Indents everything after a line occurs if in multiline and if in singleline
-- then indent.
nest :: Int -> Fmt -> Fmt
nest i a = a <|> (P.nest i <$> a)

-- | A space.
space :: Fmt
space = modify (\s -> s {lastOutput = Just Space}) >> pure P.space

-- | Forces a line to be used regardless of layout, this should
-- ideally not be used.
hardline :: Fmt
hardline = do
  modify $ \s -> s {lastOutput = Just Line}
  pure P.line

-- | A line or a space depending on layout.
line :: Fmt
line = space <|> hardline

-- | Seperates element by a @s@ followed by a space in singleline layout and
-- seperates by a line followed by a @s@ in multine layout.
sepLine :: Fmt -> [Fmt] -> Fmt
sepLine s = sep (s <> space <|> hardline <> s)

-- | A comment.
comment :: T.Text -> Fmt
comment c = do
  modify (\s -> s {lastOutput = Just Line})
  pure $ P.annotate commentStyle (P.pretty (T.stripEnd c)) <> P.line

sep :: Fmt -> [Fmt] -> Fmt
sep _ [] = nil
sep s (a : as) = auxiliary a as
  where
    auxiliary acc [] = acc
    auxiliary acc (x : xs) = auxiliary (acc <> s <> x) xs

sepComments :: (a -> Loc) -> (a -> Fmt) -> Fmt -> [a] -> Fmt
sepComments _ _ _ [] = nil
sepComments floc fmt s (a : as) = auxiliary (fmt a) as
  where
    auxiliary acc [] = acc
    auxiliary acc (x : xs) =
      auxiliary (acc <> prependComments floc (\y -> s <> fmt y) x) xs

sepLineComments :: (a -> Loc) -> (a -> Fmt) -> Fmt -> [a] -> Fmt
sepLineComments floc fmt s =
  sepComments floc fmt (s <> space <|> hardline <> s)

-- | This is used for function arguments. It seperates multiline
-- arguments by lines and singleline arguments by spaces. We specially
-- handle the case where all the arguments are on a single line except
-- for the last one, which may continue to the next line.
sepArgs :: (Located a) => (a -> Fmt) -> NE.NonEmpty a -> Fmt
sepArgs fmt ls =
  localLayout locs $ align' $ sep line $ map fmtArg ls'
  where
    locs = map (locStart . locOf) ls'
    align' = case lineLayout locs of
      Just SingleLine -> id
      _ -> align
    fmtArg x = localLayout x $ fmt x
    ls' = NE.toList ls

-- | Nest but with the standard value of two spaces.
stdNest :: Fmt -> Fmt
stdNest = nest 2

-- | Aligns line by line.
align :: Fmt -> Fmt
align a = do
  modify (\s -> s {lastOutput = Just Line}) -- XXX?
  P.align <$> a

-- | Indents everything by @i@, should never be used.
hardIndent :: Int -> Fmt -> Fmt
hardIndent i a = P.indent i <$> a

-- | Indents if in multiline by @i@ if in singleline it does not indent.
indent :: Int -> Fmt -> Fmt
indent i a = a <|> hardIndent i a

-- | Hard indents with the standard size of two.
hardStdIndent :: Fmt -> Fmt
hardStdIndent = hardIndent 2

-- | Idents with the standard size of two.
stdIndent :: Fmt -> Fmt
stdIndent = indent 2

-- | Creates a piece of text, it should not contain any new lines.
text :: AnsiStyle -> T.Text -> Fmt
text style t = do
  modify (\s -> s {lastOutput = Just Text})
  pure $ P.annotate style $ P.pretty t

-- | Adds brackets.
brackets :: Fmt -> Fmt
brackets a = "[" <> a <> "]"

-- | Adds braces.
braces :: Fmt -> Fmt
braces a = "{" <> a <> "}"

-- | Add parenthesis.
parens :: Fmt -> Fmt
parens a = "(" <> a <> ")"

-- | If in a singleline layout then concatenate with 'nil' and in multiline
-- concatenate by a line.
(<:/>) :: Fmt -> Fmt -> Fmt
a <:/> b = a <> (nil <|> hardline) <> b

-- | Concatenate with a space between.
(<+>) :: Fmt -> Fmt -> Fmt
a <+> b = a <> space <> b

-- | Concatenate with a space if in singleline layout and concatenate by a
-- line in multiline.
(</>) :: Fmt -> Fmt -> Fmt
a </> b = a <> line <> b

-- | If in a singleline layout then choose @a@, if in a multiline layout choose
-- @b@.
(<|>) :: Fmt -> Fmt -> Fmt
a <|> b = do
  lo <- ask
  if lo == SingleLine
    then a
    else b

-- | Are these locations on consecutive lines?
consecutive :: Loc -> Loc -> Bool
consecutive (Loc _ end) (Loc beg _) = posLine end + 1 == posLine beg
consecutive _ _ = False

-- | If in singleline layout seperate by spaces. In a multiline layout seperate
-- by a single line if two neighbouring elements are singleline. Otherwise
-- sepereate by two lines.
sepDecs :: (Located a) => (a -> Fmt) -> [a] -> Fmt
sepDecs _ [] = nil
sepDecs fmt decs@(x : xs) =
  sep space (map fmt decs) <|> (fmt x <> auxiliary x xs)
  where
    auxiliary _ [] = nil
    auxiliary prev (y : ys) = p <> fmt y <> auxiliary y ys
      where
        p = do
          commented <- hasComment y
          case (commented, lineLayout y, lineLayout prev) of
            (False, Just SingleLine, Just SingleLine)
              | consecutive (locOf prev) (locOf y) -> hardline
            _any -> hardline <> hardline
