module Lisa.Parser exposing
    ( AstNode
    , SExpr(..)
    , parse
    )

{-|

@docs AstNode
@docs SExpr
@docs parse

-}

import Lisa.Common
    exposing
        ( Error
        , LocatedNode
        , Location
        , Recoverable(..)
        , encodeError
        , encodeWithLocation
        )
import Maybe
import Parser.Advanced as Parser exposing (..)
import Set exposing (Set)


type Problem
    = ExpectedExpr
    | ExpectedListEnd
    | UnexpectedStringEnd
    | InvalidNumber
    | InvalidStringEscape
    | Never


type Context
    = StrLit
    | ListLit
    | TopCtx


type alias Parser a =
    Parser.Parser Context Problem a


type alias ParserError =
    DeadEnd Context Problem


{-| -}
type SExpr
    = List (List AstNode)
    | Symbol String
    | Str String
    | Num Float


{-| -}
type alias AstNode =
    LocatedNode SExpr


locatedParse : ( Int, Int ) -> a -> ( Int, Int ) -> LocatedNode a
locatedParse start node end =
    LocatedNode (Location start end) node


reprErr : ParserError -> Error
reprErr err =
    let
        -- hacky, I don't know why this is necessary
        currentCtx =
            case err.contextStack of
                [] ->
                    Nothing

                top :: rest ->
                    Just <|
                        case top.context of
                            ListLit ->
                                List.head rest |> Maybe.withDefault top

                            _ ->
                                top

        ( startPos, context ) =
            case currentCtx of
                Just c ->
                    ( ( c.row, c.col ), c.context )

                Nothing ->
                    ( ( 1, 1 ), TopCtx )
    in
    Error
        (case err.problem of
            ExpectedListEnd ->
                Recoverable

            _ ->
                Nonrecoverable
        )
        (Location startPos ( err.row, err.col ))
        (errorToString err)


errorToString : ParserError -> String
errorToString err =
    case err.problem of
        ExpectedExpr ->
            "Expected an expression, like a list: (a b c), string: \"abc\", or number: 123"

        ExpectedListEnd ->
            "Expected the end of a list, but couldn't find it. Try adding a ')'."

        UnexpectedStringEnd ->
            "Couldn't find a closing '\"' for string literal."

        InvalidNumber ->
            "You have a malformed number literal."

        InvalidStringEscape ->
            "You have an invalid character after a '\\' in your string. To "
                ++ "represent a raw '\\', you need to put 2 of them, like: '\\\\'"

        Never ->
            "You should never see this error message"


{-| -}
parse : String -> Result Error (List AstNode)
parse input =
    Parser.run parser input
        |> Result.mapError
            (\err ->
                List.head err
                    |> Maybe.withDefault
                        { row = 0
                        , col = 0
                        , problem = Never
                        , contextStack = []
                        }
                    |> reprErr
            )


parser : Parser (List AstNode)
parser =
    inContext TopCtx <|
        succeed identity
            |= program
            |. end ExpectedExpr


program : Parser (List AstNode)
program =
    sequence
        { start = Token "" Never
        , separator = Token "" Never
        , end = Token "" Never
        , spaces = spaces
        , item = expr
        , trailing = Optional
        }


expr : Parser AstNode
expr =
    succeed locatedParse
        |= getPosition
        |= oneOf
            [ map Symbol symbol
            , map Num float
            , map Str string
            , map List list
            ]
        |= getPosition


float : Parser Float
float =
    Parser.float ExpectedExpr InvalidNumber


symbol : Parser String
symbol =
    variable
        { start = symbolHelper
        , inner = \c -> Char.isDigit c || symbolHelper c
        , reserved = Set.empty
        , expecting = ExpectedExpr
        }


validSymbols : Set Char
validSymbols =
    Set.fromList
        [ '+'
        , '-'
        , '*'
        , '/'
        , '?'
        , '='
        , '<'
        , '>'
        ]


symbolHelper : Char -> Bool
symbolHelper c =
    Char.isAlpha c || Set.member c validSymbols


list : Parser (List AstNode)
list =
    inContext ListLit <|
        (succeed identity
            |. token (Token "(" ExpectedExpr)
            |= loop [] listHelp
            |> andThen
                (\maybeElems ->
                    case maybeElems of
                        Just elems ->
                            succeed elems

                        Nothing ->
                            problem ExpectedListEnd
                )
        )


listHelp : List AstNode -> Parser (Step (List AstNode) (Maybe (List AstNode)))
listHelp revElems =
    succeed identity
        |. spaces
        |= oneOf
            [ lazy (\_ -> expr) |> map (\elem -> Loop <| elem :: revElems)
            , token (Token ")" ExpectedListEnd) |> map (\_ -> Done <| Just <| List.reverse revElems)
            , end Never |> map (\_ -> Done Nothing)
            ]



-- STRINGS


string : Parser String
string =
    inContext StrLit <|
        (succeed identity
            |. token (Token "\"" ExpectedExpr)
            |= loop [] stringHelp
            |> andThen
                (\maybe ->
                    case maybe of
                        Just str ->
                            succeed str

                        Nothing ->
                            problem UnexpectedStringEnd
                )
        )


stringHelp : List String -> Parser (Step (List String) (Maybe String))
stringHelp revChunks =
    oneOf
        [ succeed (\chunk -> Loop (chunk :: revChunks))
            |. token (Token "\\" InvalidStringEscape)
            |= oneOf
                [ map (\_ -> "\n") (token (Token "n" InvalidStringEscape))
                , map (\_ -> "\t") (token (Token "t" InvalidStringEscape))
                , map (\_ -> "\"") (token (Token "\"" InvalidStringEscape))
                , map (\_ -> "\\") (token (Token "\\" InvalidStringEscape))
                ]
        , token (Token "\"" UnexpectedStringEnd)
            |> map
                (\_ ->
                    List.reverse revChunks |> String.join "" |> Just |> Done
                )
        , map (\_ -> Done Nothing) (end UnexpectedStringEnd)
        , chompWhile isUninteresting
            |> getChompedString
            |> map (\chunk -> Loop (chunk :: revChunks))
        ]


isUninteresting : Char -> Bool
isUninteresting char =
    char /= '\\' && char /= '"'
