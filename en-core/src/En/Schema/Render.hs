-- | Human-readable schema renderers.
--
-- These folds are for documentation and visualization, not hashing. They preserve
-- the same deterministic map/set traversal order as schema hashing while emitting
-- Markdown and Mermaid text meant for people to read.
module En.Schema.Render
  ( renderMarkdown,
    renderMermaid,
    renderReachabilityMermaid,
  )
where

import Data.Char (isAlphaNum)
import Data.Generics.Labels ()
import Data.List (intersperse)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import En.Prelude
import En.Reachability
  ( EntryKind (..),
    EntryPoint (..),
    RelationRef (..),
    SubjectSelector (..),
    entryPoints,
  )
import En.Schema
  ( AllowedSubject (..),
    CaveatDefinition (..),
    CaveatName (..),
    CaveatParameterName (..),
    CaveatParameterType (..),
    ObjectType (..),
    Relation (..),
    RelationName (..),
    Rewrite (..),
    Schema (..),
    ValidSchema,
  )

-- | Fold a schema into a Markdown reference document.
renderMarkdown :: Schema -> Text
renderMarkdown schema =
  Text.intercalate
    "\n"
    ( ["# Schema reference", ""]
        <> joinBlocks (renderObject <$> Map.toAscList (schema ^. #objectTypes))
        <> ["", "## Caveats", ""]
        <> renderCaveats
    )
  where
    renderObject (objectType, relations) =
      [ "## " <> objectText objectType,
        ""
      ]
        <> if Map.null relations
          then ["(no relations)"]
          else renderRelation <$> Map.toAscList relations

    renderRelation (RelationName relationName, relation) =
      "- **"
        <> relationName
        <> "** — subjects: "
        <> renderSubjects (relation ^. #allowedSubjects)
        <> "; rule: "
        <> renderRewrite (relation ^. #rewrite)

    renderCaveats
      | Map.null (schema ^. #caveats) = ["(none)"]
      | otherwise = renderCaveat <$> Map.toAscList (schema ^. #caveats)

    renderCaveat (CaveatName caveatName, caveat) =
      "- **"
        <> caveatName
        <> "** — parameters: "
        <> renderParameters (caveat ^. #parameters)

-- | Fold a schema into a Mermaid flowchart of declared object types and relations.
renderMermaid :: Schema -> Text
renderMermaid schema =
  Text.unlines
    ( ["flowchart LR"]
        <> [ "  " <> objectId objectType <> "[\"" <> escapeMermaidLabel (objectText objectType) <> "\"]"
           | objectType <- Map.keys (schema ^. #objectTypes)
           ]
        <> concatMap renderObjectEdges (Map.toAscList (schema ^. #objectTypes))
    )
  where
    renderObjectEdges (objectType, relations) =
      concatMap (renderRelationEdges objectType) (Map.toAscList relations)

    renderRelationEdges objectType (relationName, relation) =
      case (relation ^. #rewrite) of
        This ->
          [ edge Solid (objectId objectType) (objectId (subject ^. #objectType)) (directEdgeLabel relationName subject)
          | subject <- Set.toAscList (relation ^. #allowedSubjects)
          ]
        rewrite ->
          [ edge (rewriteEdgeStyle rewrite) (objectId objectType) (objectId objectType) (relationNameText relationName <> " = " <> renderRewrite rewrite)
          ]

-- | Fold a schema's resolved entry points into a Mermaid flowchart.
--
-- Takes the 'ValidSchema' rather than the compiled 'En.Reachability.ReachabilityGraph':
-- entry points are reverse-edge metadata for a reader, and the graph is what the
-- engines traverse. This function is the only consumer of 'entryPoints' in the
-- workspace.
renderReachabilityMermaid :: ValidSchema -> Text
renderReachabilityMermaid valid =
  Text.unlines
    ( ["flowchart LR"]
        <> renderNodes
        <> concatMap renderEntries (Map.toAscList graphEntries)
    )
  where
    graphEntries =
      entryPoints valid

    renderNodes =
      Set.toAscList $
        Set.fromList
          ( [ node (relationRefId target) (renderRelationRef target)
            | target <- Map.keys graphEntries
            ]
              <> [ node (subjectSelectorId (entry ^. #source)) (renderSubjectSelector (entry ^. #source))
                 | entries <- Map.elems graphEntries,
                   entry <- entries
                 ]
          )

    renderEntries (target, entries) =
      [ edge
          (entryStyle entry)
          (subjectSelectorId (entry ^. #source))
          (relationRefId target)
          (entryLabel entry)
      | entry <- entries
      ]

    node identifier label =
      "  " <> identifier <> "[\"" <> escapeMermaidLabel label <> "\"]"

renderSubjects :: Set.Set AllowedSubject -> Text
renderSubjects subjects
  | Set.null subjects = "(none)"
  | otherwise = Text.intercalate ", " (renderAllowedSubject <$> Set.toAscList subjects)

renderAllowedSubject :: AllowedSubject -> Text
renderAllowedSubject subject =
  objectText (subject ^. #objectType)
    <> maybe "" (("#" <>) . relationNameText) (subject ^. #relation)
    <> if subject ^. #wildcard then ":*" else ""

renderParameters :: Map.Map CaveatParameterName CaveatParameterType -> Text
renderParameters parameters
  | Map.null parameters = "(none)"
  | otherwise =
      Text.intercalate
        ", "
        [ parameterNameText name <> ": " <> renderParameterType parameterType
        | (name, parameterType) <- Map.toAscList parameters
        ]

renderParameterType :: CaveatParameterType -> Text
renderParameterType =
  \case
    ParameterText -> "text"
    ParameterBool -> "bool"
    ParameterInteger -> "integer"
    ParameterTimestamp -> "timestamp"
    ParameterEnum values -> "enum[" <> Text.intercalate ", " (Set.toAscList (Set.fromList values)) <> "]"

renderRewrite :: Rewrite -> Text
renderRewrite =
  \case
    This -> "directly assigned"
    ComputedUserset relationName -> relationNameText relationName
    TupleToUserset tupleset computed -> relationNameText tupleset <> "→" <> relationNameText computed
    Union rewrites -> Text.intercalate " ∪ " (renderRewrite <$> rewrites)
    Intersection rewrites -> Text.intercalate " ∩ " (renderRewrite <$> rewrites)
    Exclusion left right -> renderRewrite left <> " ∖ " <> renderRewrite right
    Caveated caveatName rewrite -> renderRewrite rewrite <> " [" <> caveatText caveatName <> "]"

data EdgeStyle
  = Solid
  | Dotted

edge :: EdgeStyle -> Text -> Text -> Text -> Text
edge style from to label =
  case style of
    Solid -> "  " <> from <> " -->" <> solidLabel label <> " " <> to
    Dotted -> "  " <> from <> " -. " <> quotedLabel label <> " .-> " <> to

solidLabel :: Text -> Text
solidLabel label
  | Text.all simpleLabelChar label = "|" <> label <> "|"
  | otherwise = "|\"" <> escapeMermaidLabel label <> "\"|"

quotedLabel :: Text -> Text
quotedLabel label =
  "\"" <> escapeMermaidLabel label <> "\""

simpleLabelChar :: Char -> Bool
simpleLabelChar char =
  isAlphaNum char || char == '_' || char == '#' || char == ':' || char == '*'

directEdgeLabel :: RelationName -> AllowedSubject -> Text
directEdgeLabel relationName subject =
  relationNameText relationName
    <> case (subject ^. #relation) of
      Nothing ->
        if (subject ^. #wildcard)
          then " (" <> objectText (subject ^. #objectType) <> ":*)"
          else ""
      Just subjectRelation ->
        " (" <> objectText (subject ^. #objectType) <> "#" <> relationNameText subjectRelation <> ")"

rewriteEdgeStyle :: Rewrite -> EdgeStyle
rewriteEdgeStyle rewrite
  | hasCaveat rewrite = Dotted
  | otherwise = Solid

entryStyle :: EntryPoint -> EdgeStyle
entryStyle entry
  | (entry ^. #kind) == Conditional || not (null (entry ^. #caveats)) = Dotted
  | otherwise = Solid

entryLabel :: EntryPoint -> Text
entryLabel entry =
  relationRefText (entry ^. #target)
    <> if null (entry ^. #caveats)
      then ""
      else " [" <> Text.intercalate ", " (caveatText <$> entry ^. #caveats) <> "]"

hasCaveat :: Rewrite -> Bool
hasCaveat =
  \case
    This -> False
    ComputedUserset _ -> False
    TupleToUserset _ _ -> False
    Union rewrites -> any hasCaveat rewrites
    Intersection rewrites -> any hasCaveat rewrites
    Exclusion left right -> hasCaveat left || hasCaveat right
    Caveated _ _ -> True

renderRelationRef :: RelationRef -> Text
renderRelationRef ref =
  relationRefText ref

renderSubjectSelector :: SubjectSelector -> Text
renderSubjectSelector selector =
  objectText (selector ^. #objectType)
    <> maybe "" (("#" <>) . relationNameText) (selector ^. #relation)
    <> if selector ^. #wildcard then ":*" else ""

objectId :: ObjectType -> Text
objectId =
  mermaidId "object" . objectText

relationRefId :: RelationRef -> Text
relationRefId ref =
  mermaidId "relation" (relationRefText ref)

subjectSelectorId :: SubjectSelector -> Text
subjectSelectorId selector =
  mermaidId "subject" (renderSubjectSelector selector)

mermaidId :: Text -> Text -> Text
mermaidId prefix value =
  prefix <> "_" <> Text.map sanitizeIdChar value

sanitizeIdChar :: Char -> Char
sanitizeIdChar char
  | isAlphaNum char || char == '_' = char
  | otherwise = '_'

escapeMermaidLabel :: Text -> Text
escapeMermaidLabel =
  Text.concatMap \case
    '"' -> "\\\""
    '\\' -> "\\\\"
    char -> Text.singleton char

objectText :: ObjectType -> Text
objectText (ObjectType text) =
  text

relationNameText :: RelationName -> Text
relationNameText (RelationName text) =
  text

caveatText :: CaveatName -> Text
caveatText (CaveatName text) =
  text

parameterNameText :: CaveatParameterName -> Text
parameterNameText (CaveatParameterName text) =
  text

relationRefText :: RelationRef -> Text
relationRefText ref =
  objectText (ref ^. #objectType) <> "#" <> relationNameText (ref ^. #relation)

joinBlocks :: [[Text]] -> [Text]
joinBlocks =
  concat . intersperse [""]
