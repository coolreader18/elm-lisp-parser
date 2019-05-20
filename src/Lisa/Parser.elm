module Lisa.Parser exposing
    ( AstNode
    , ParserError
    , SExpr(..)
    , encodeExpr
    , errorToString
    , parse
    , parseToJson
    )

import Common
    exposing
        ( Error
        , LocatedNode
        , Location
        , encodeError
        , encodeWithLocation
        )
import Json.Encode as E
import Maybe
import Parser.Advanced as Parser exposing (..)
import Set exposing (Set)


type Problem
    = ExpectedExpr
    | ExpectedKeyName
    | ExpectedListEnd
    | UnexpectedStringEnd
    | InvalidNumber
    | InvalidStringEscape
    | Never


type Context
    = StrLit
    | ListLit
    | KeyLit
    | TopCtx


type alias Parser a =
    Parser.Parser Context Problem a


type alias ParserError =
    DeadEnd Context Problem


type SExpr
    = List (List AstNode)
    | Symbol String
    | Str String
    | Num Float
    | Key String


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
    Error (Location startPos ( err.row, err.col )) (errorToString err)


pickErr : List ParserError -> Maybe ParserError
pickErr errs =
    errs
        |> List.sortBy
            (\err ->
                case err.problem of
                    ExpectedKeyName ->
                        1

                    _ ->
                        10
            )
        |> List.head


errorToString : ParserError -> String
errorToString err =
    case err.problem of
        ExpectedExpr ->
            "Expected an expression, like a list: (a b c), string: \"abc\", or number: 123"

        ExpectedKeyName ->
            "Expected the name of a key. There cannot be any spaces between the '@' and the key name"

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


encodeContext : Context -> E.Value
encodeContext context =
    E.string <|
        case context of
            StrLit ->
                "str"

            ListLit ->
                "list"

            KeyLit ->
                "key"

            TopCtx ->
                "top"


encodeExpr : AstNode -> E.Value
encodeExpr { loc, node } =
    encodeWithLocation loc <| encodeSExpr node


encodeSExpr : SExpr -> List ( String, E.Value )
encodeSExpr sExpr =
    case sExpr of
        List l ->
            [ ( "type", E.string "list" )
            , ( "children", E.list encodeExpr l )
            ]

        Symbol sym ->
            [ ( "type", E.string "symbol" )
            , ( "ident", E.string sym )
            ]

        Str str ->
            [ ( "type", E.string "str" )
            , ( "value", E.string str )
            ]

        Num num ->
            [ ( "type", E.string "num" )
            , ( "value", E.float num )
            ]

        Key k ->
            [ ( "type", E.string "key" )
            , ( "name", E.string k )
            ]


parseToJson : String -> E.Value
parseToJson input =
    case parse input of
        Ok parsed ->
            E.object
                [ ( "status", E.string "ok" )
                , ( "parsed", E.list encodeExpr parsed )
                ]

        Err err ->
            E.object
                [ ( "status", E.string "err" )
                , ( "error", encodeError err )
                ]


parse : String -> Result Error (List AstNode)
parse input =
    Parser.run parser input
        |> Result.mapError
            (\err ->
                pickErr err
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
            [ map List list
            , map Symbol symbol
            , map Num float
            , map Key key
            , map Str string
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
        ]


symbolHelper : Char -> Bool
symbolHelper c =
    Char.isAlpha c || Set.member c validSymbols


list : Parser (List AstNode)
list =
    inContext ListLit <|
        sequence
            { start = Token "(" ExpectedExpr
            , separator = Token "" Never
            , end = Token ")" ExpectedListEnd
            , spaces = spaces
            , item = lazy (\_ -> expr)
            , trailing = Optional
            }


key : Parser String
key =
    inContext KeyLit <|
        (succeed identity
            |. Parser.symbol (Token "@" ExpectedExpr)
            |= variable
                { start = Char.isAlphaNum
                , inner = Char.isAlphaNum
                , reserved = Set.empty
                , expecting = ExpectedKeyName
                }
        )



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