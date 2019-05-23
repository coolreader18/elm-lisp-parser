module Common exposing
    ( Error
    , LocatedNode
    , Location
    , Recoverable(..)
    , encodeError
    , encodeWithLocation
    , errNode
    , foldlListResult
    , foldrListResult
    , mapListResult
    , mapNode
    , nonRecovErrNode
    , nonRecovError
    )

import Json.Encode as E


type Recoverable
    = Recoverable
    | Nonrecoverable


type alias Error =
    { recoverable : Recoverable
    , loc : Location
    , msg : String
    }


type alias Location =
    { start : ( Int, Int )
    , end : ( Int, Int )
    }


type alias LocatedNode a =
    { loc : Location
    , node : a
    }


encodeWithLocation : Location -> List ( String, E.Value ) -> E.Value
encodeWithLocation loc obj =
    let
        ( startRow, startCol ) =
            loc.start

        ( endRow, endCol ) =
            loc.end
    in
    E.object <|
        ( "location"
        , E.object
            [ ( "startRow", E.int startRow )
            , ( "startCol", E.int startCol )
            , ( "endRow", E.int endRow )
            , ( "endCol", E.int endCol )
            ]
        )
            :: obj


encodeError : Error -> E.Value
encodeError { recoverable, loc, msg } =
    encodeWithLocation loc
        [ ( "recoverable"
          , case recoverable of
                Recoverable ->
                    E.bool True

                Nonrecoverable ->
                    E.bool False
          )
        , ( "msg", E.string msg )
        ]


mapNode : LocatedNode a -> b -> LocatedNode b
mapNode { loc } b =
    { loc = loc, node = b }


errNode : Recoverable -> LocatedNode a -> String -> Error
errNode recov { loc } msg =
    Error recov loc msg


foldlListResult : (a -> b -> Result e b) -> b -> List a -> Result e b
foldlListResult func acc =
    List.foldl (Result.andThen << func) (Ok acc)


foldrListResult : (a -> b -> Result e b) -> b -> List a -> Result e b
foldrListResult func acc =
    List.foldr (Result.andThen << func) (Ok acc)


mapListResult : (a -> Result e b) -> List a -> Result e (List b)
mapListResult func =
    foldrListResult (\a list -> func a |> Result.map (\b -> b :: list)) []


nonRecovError : Location -> String -> Error
nonRecovError =
    Error Nonrecoverable


nonRecovErrNode : LocatedNode a -> String -> Error
nonRecovErrNode =
    errNode Nonrecoverable
