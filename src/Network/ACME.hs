module Network.ACME
  ( module Network.ACME
  , module X
  ) where

import Control.Monad.Trans.Except
import Crypto.JOSE
import Data.Aeson
import Data.Aeson.Types (emptyObject)
import qualified Data.ByteString.Lazy.Char8 as L
import Data.Foldable
import Data.Maybe
import qualified Data.X509 as X509

import Network.ACME.Errors as X
import Network.ACME.HTTP
import Network.ACME.JWS as X
import Network.ACME.Types as X

-- * Perform Requests
-- ** Directory
-- | Get all supported resources from server
acmePerformDirectory :: AcmeRequestDirectory
                     -> ExceptT RequestError IO AcmeObjDirectory
acmePerformDirectory acmeReq =
  addDirectory <$> (acmeHttpGet acmeReq >>= resBody)
    -- TODO: Boulder workaround
  where
    addDirectory x = x {acmeObjDirectory = Just acmeReq}

-- ** Account
-- | Registeres new account
acmePerformAccountNew :: AcmeObjAccount
                      -> AcmeObjDirectory
                      -> ExceptT RequestError IO AcmeObjAccount
acmePerformAccountNew acc dir = do
  body <- acmeNewJwsBody req acc acc dir
  acmeHttpPost req body >>= resBody
  where
    req = fromJust $ acmeObjDirectoryNewReg dir

-- TODO: Only supports bolder legacy
-- | Recover the account uri
acmePerformAccountURI
  :: AcmeObjAccount
  -> AcmeObjDirectory
  -> ExceptT RequestError IO AcmeRequestAccountUpdate
acmePerformAccountURI acc dir = do
  body <- acmeNewJwsBody req emptyObject acc dir
  res <- acmeHttpPost req body
  AcmeRequestAccountUpdate <$> resHeaderAsURI "Location" res
  where
    req =
      AcmeRequestAccountURI $
      acmeRequestUrl $ fromJust $ acmeObjDirectoryNewReg dir

-- TODO: Only supports bolder legacy
-- | Update account
acmePerformAccountUpdate :: AcmeObjAccount
                         -> AcmeObjDirectory
                         -> ExceptT RequestError IO AcmeObjAccount
acmePerformAccountUpdate acc dir = do
  req <- acmePerformAccountURI acc dir
  body <- acmeNewJwsBody req acc acc dir
  acmeHttpPost req body >>= resBody

-- | Key Roll-over
acmePerformAccountKeyRollover
  :: AcmeObjAccount -- ^ Account with current key
  -> AcmeObjAccount -- ^ Same account with new key
  -> AcmeObjDirectory
  -> ExceptT RequestError IO AcmeObjAccount
acmePerformAccountKeyRollover current new dir =
  case acmeObjDirectoryKeyChange dir of
    Nothing -> throwE (RequestNotSupported "key-change")
    Just req -> do
      accUrl <- acmePerformAccountURI current dir
      let objRollover =
            AcmeObjAccountKeyRollover (jwkPublic $ acmeObjAccountKey new) accUrl
      innerJws <- acmeNewJwsBody req objRollover new dir
      outerJws <- acmeNewJwsBody req innerJws current dir
      acmeHttpPost req outerJws >>= resBody

-- ** Authorization
-- | New authorization
acmePerformAuthorizationNew
  :: AcmeObjAuthorizationNew
  -> AcmeObjAccount
  -> AcmeObjDirectory
  -> ExceptT RequestError IO AcmeObjAuthorization
acmePerformAuthorizationNew authz acc dir =
  case acmeObjDirectoryNewAuthz dir of
    Nothing -> throwE (RequestNotSupported "new-authz")
    Just req -> do
      body <- acmeNewJwsBody req authz acc dir
      acmeHttpPost req body >>= resBody

-- | Existing authorization
acmePerformAuthorizationExisting
  :: AcmeObjAuthorizationNew
  -> AcmeObjAccount
  -> AcmeObjDirectory
  -> ExceptT RequestError IO AcmeObjAuthorization
acmePerformAuthorizationExisting authz acc dir =
  case acmeObjDirectoryNewAuthz dir of
    Nothing -> throwE (RequestNotSupported "new-authz")
    Just req -> do
      body <- acmeNewJwsBody (reqMod req) authzMod acc dir
      acmeHttpPost req body >>= resBody
  where
    authzMod = authz {acmeObjNewAuthzExisting = Just "require"}
    reqMod :: AcmeRequestAuthorziationNew -> AcmeRequestAuthorizationExisting
    reqMod = AcmeRequestAuthorizationExisting . acmeRequestUrl

-- | Respond to challenge
acmePerformChallengeRespond
  :: AcmeRequestChallengeResponse
  -> AcmeObjChallengeResponse
  -> AcmeObjAccount
  -> AcmeObjDirectory
  -> ExceptT RequestError IO AcmeObjChallenge
acmePerformChallengeRespond req ch acc dir = do
  body <- acmeNewJwsBody req ch acc dir
  acmeHttpPost req body >>= resBody

-- ** Certificate
-- | Create new application (handing in a certificate request)
acmePerformOrderNew
  :: AcmeObjOrder
  -> AcmeObjAccount
  -> AcmeObjDirectory
  -> ExceptT RequestError IO X509.SignedCertificate
acmePerformOrderNew app acc dir =
  case guessedNewOrderRequest of
    Nothing -> throwE (RequestNotSupported "new-app")
    Just req -> do
      reqBody <- acmeNewJwsBody req app acc dir
      res <- acmeHttpPost req reqBody
      decodeCert $ acmeResponseBody res
  where
    guessedNewOrderRequest =
      case acmeObjDirectoryNewOrder dir of
        Nothing -> acmeObjDirectoryNewCert dir
        x -> x
    decodeCert b =
      case X509.decodeSignedCertificate (L.toStrict b) of
        Right c -> return c
        Left e -> throwE (ErrDecodeX509 e (show b))

-- ** Nonce
-- | Get new nonce
acmePerformNonce :: AcmeObjDirectory -> ExceptT RequestError IO AcmeJwsNonce
acmePerformNonce d =
  AcmeJwsNonce <$> (acmeHttpHead req >>= resHeader "Replay-Nonce")
  where
    req = guessNonceRequest d
    -- TODO: Fallback to directory url, since Boulder does not implement /new-nonce/
    guessNonceRequest :: AcmeObjDirectory -> AcmeRequestNonceNew
    guessNonceRequest AcmeObjDirectory {..} =
      case acmeObjDirectoryNewNonce of
        Just x -> x
        Nothing ->
          AcmeRequestNonceNew (acmeRequestUrl $ fromJust acmeObjDirectory)

-- * Utils
-- ** Object generation
acmeNewObjAccountStub :: String -> IO AcmeObjAccount
acmeNewObjAccountStub mail = do
  keyMat <- genKeyMaterial (RSAGenParam 256)
  return
    AcmeObjAccount
    { acmeObjAccountKey = keyMat
    , acmeObjAccountContact = Just ["mailto:" ++ mail]
    , acmeObjAccountStatus = Nothing
    , acmeObjAccountTermsOfServiceAgreed = Nothing
    , acmeObjAccountOrders = Nothing
    , acmeObjAccountAgreement = Nothing
    }

acmeNewObjOrder :: Base64Octets -> AcmeObjOrder
acmeNewObjOrder xs =
  AcmeObjOrder
  { acmeObjOrderCsr = xs
  , acmeObjOrderNot_Before = Nothing
  , acmeObjOrderNot_After = Nothing
  }

-- ** Object inquiry 
acmeGetPendingChallenge
  :: String -- ^ Type
  -> AcmeObjAuthorization
  -> ExceptT RequestError IO AcmeObjChallenge
acmeGetPendingChallenge t =
  maybeToExceptT (AcmeErrNoChallenge t) . acmeMaybePendingChallenge t

acmeMaybePendingChallenge
  :: String -- ^ Type
  -> AcmeObjAuthorization
  -> Maybe AcmeObjChallenge
acmeMaybePendingChallenge t authz =
  find cond (acmeObjAuthorizationChallenges authz)
  where
    cond x =
      acmeObjChallengeStatus x == "pending" && acmeObjChallengeType x == t

-- ** Other
acmeKeyAuthorization :: AcmeObjChallenge
                     -> AcmeObjAccount
                     -> ExceptT RequestError IO String
acmeKeyAuthorization ch acc =
  case acmeObjChallengeToken ch of
    Nothing -> throwE $ AcmeErrNoToken ch
    Just token -> return $ token ++ "." ++ jwkThumbprint (acmeObjAccountKey acc)

{-|
Creates a signed JWS object in ACME format. This implies interaction with the
ACME server for obtaining a valid nonce for this request.
-}
acmeNewJwsBody
  :: (AcmeRequest a, ToJSON o)
  => a -- ^ For example from 'AcmeObjDirectory'
  -> o -- ^ Request body
  -> AcmeObjAccount -- ^ Account signing the request
  -> AcmeObjDirectory -- ^ Directory of the server
  -> ExceptT RequestError IO (AcmeJws)
acmeNewJwsBody req obj acc dir = do
  nonce <- acmePerformNonce dir
  RequestJwsError `withExceptT`
    (AcmeJws <$>
     jwsSigned obj (acmeRequestUrl req) (acmeObjAccountKey acc) nonce)
