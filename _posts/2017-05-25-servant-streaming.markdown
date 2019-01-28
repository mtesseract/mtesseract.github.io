---
layout: post
title:  "Example: Conduit Streaming with Servant"
date:   2017-05-25
categories: conduit servant streaming
---

[Servant](http://haskell-servant.readthedocs.io/en/stable/) is an awesome set of Haskell packages for Web development. Under the hood the Servant server uses [WAI](http://www.yesodweb.com/book/web-application-interface) and Warp. Forunately, the package [wai-conduit](https://www.stackage.org/lts-8.15/package/wai-conduit-3.0.0.3) provides support for creating HTTP responses from Conduit sources, which also allow for streaming responses from within a Servant server.

Edsko de Vries has described the basic mechanism for doing this in a [Github comment](https://github.com/haskell-servant/servant/issues/271#issuecomment-258079285).

This post describes this in more detail, giving a complete example (which can be cloned from its repository).

Let us start! The server API type for a trivial non-streaming example looks like this:

```haskell
type ServiceAPI = "one" :> Get '[JSON] Int
```

A handler implementing this endpoint is expected to return a value of type Int and Servant takes care of serializing this value before sending it to the client. An implementation for this API can look like this:

```haskell
serveAPI :: Server ServiceAPI
serveAPI = serveOne

serveOne :: Handler Int
serveOne = return 1
```

Now, imagine we want to implement an endpoint `/ones`, which streams infinitely many ones. Say we would like to use Conduit, then a reasonable handler type for the endpoint `/ones` would look like this:

```haskell
serveOnes :: Handler (Source (ResourceT IO) (Flush ByteString))
```

Note: See the Conduit documentation for information on the Flush type.

Given the above type, an implementation for serveOnes could look as follows:

```haskell
serveOnes = return go
  where go = do
          yield (Chunk "1")
          yield Flush
          go
```

Now, in order to be able to use this handler for implementing a Servant API, we need to extend Servant’s Web API DSL. Say we would like to extend the above API with a streaming endpoint as follows:

```haskell
type ServiceAPI =
   "one" :> Get '[JSON] Int
   :<|> "ones" :> GetStream ByteString
```

We can begin by definin a new type

```haskell
data GetStream a
```

In order to be able to use GetStream for defining Servant endpoints, we need to implement a HasServer instance for it. Edsko has demonstrated a basic class implementation in his comment on Github. I would like to make this a bit more configurable by defining a new type class Streamable:

```haskell
class Streamable a where
  streamableToBuilder :: a -> Builder
  streamableCT :: Proxy a -> Maybe MediaType
  streamableCT _ = Nothing
  streamableDelimiter :: Proxy a -> Maybe Builder
  streamableDelimiter _ = Nothing
```

The method streamableToBuilder is obviously the most important method here as it allows us to convert a value of the type implementing this class into a ByteString Builder. The method streamableCT can be used for defining the response content type while streamableDelimiter can be used for defining a Builder delimiter which will be inserted in the response stream whenever the handler produces a Flush value. While we are at it, let us implement the following helper function:

```haskell
toBuilderDelimited :: forall a. Streamable a => Flush a -> [Flush Builder]
```

This function will take care of inserting delimiters on Flush values. Implementing is is straight-forward:

```haskell
toBuilderDelimited (Chunk a) = [Chunk (streamableToBuilder a)]
toBuilderDelimited Flush = case streamableDelimiter (Proxy :: Proxy a) of
                             Just delim -> [Chunk delim, Flush]
                             Nothing    -> [Flush]
```

Having this in place, we can now implement HasServer for GetStream a:

```haskell
instance Streamable a => HasServer (GetStream a) ctxt where
  type ServerT (GetStream a) m = m (Source (ResourceT IO) (Flush a))

  route Proxy _ctxt sub = leafRouter $
    \env req k ->
      bracket createInternalState
              closeInternalState
              (runAction sub env req k . mkResponse)
    where

      mkResponse :: InternalState
                 -> Source (ResourceT IO) (Flush a)
                 -> RouteResult Response
      mkResponse st =
        Route
        . responseSource ok200 headers
        . (.| CL.map toBuilderDelimited .| C.concat)
        . transPipe (`runInternalState` st)

      headers :: ResponseHeaders
      headers =
        let maybeMediaTypeBS = Media.renderHeader <$> streamableCT (Proxy :: Proxy a)
        in maybeToList $ ("Content-Type",) <$> maybeMediaTypeBS
```

The function mkResponse is responsible for converting a Conduit source into a HTTP Response. It uses the previously defined helper function toBuilderDelimited and responseSource from the wai-conduit package. The function headers takes care of producing the desired Content-Type header.

So far we don’t have any instances for Streamable. A naive implementation for ByteString might look like this:

```haskell
instance Streamable ByteString where
  streamableToBuilder = lazyByteString . ByteString.Lazy.fromStrict
```

Here we convert a (strict) ByteString to a ByteString Builder without setting any content or delimiter.

For a different use case one might want to stream newline-delimited JSON values using a content type of application/x-json-stream. The Streamable instance implementing this would be

```haskell
instance Streamable Value where
  streamableToBuilder = lazyByteString . encodingToLazyByteString . toEncoding
  streamableCT _ = Just ("application" Media.// "x-json-stream")
  streamableDelimiter _ = Just (lazyByteString "\n")
```

Given this instance, we can extend our service API by writing

```haskell
type ServiceAPI = "one" :> Get '[JSON] Int
   :<|> "ones" :> GetStream ByteString
   :<|> "hello" :> GetStream Value
```

and implement a handler for the `/hello` endpoint as follows:

```haskell
serveHello :: Handler (Source (ResourceT IO) (Flush Value))
serveHello = return go
  where go = do
          yield (Chunk (Array (Vector.replicate 10 (String "hello"))))
          yield Flush
          go
```

This produces a stream of newline-delimited JSON arrays each containing 10 strings. That’s it for now, happy streaming!
