import Foundation
import CryptoKit

public struct OIDCLiteTokenResponse {
    public var accessToken: String?
    public var idToken: String?
    public var refreshToken: String?
}

public protocol OIDCLiteDelegate {
    func authFailure(message: String)
    func tokenResponse(tokens: OIDCLiteTokenResponse)
}

public class OIDCLite {
    
    // Constants, in case nothing else is supplied
    
    public let kRedirectURI = "oidclite://openID"
    public let kDefaultScopes = ["openid", "profile", "email", "offline_access"]
    
    // OpenID settings, supplied on init()
    
    public let discoveryURL: String
    public let redirectURI: String
    public let clientID: String
    public let scopes: [String]
    public let clientSecret: String?
    
    // OpenID endpoints, gathered from the discoveryURL
    
    public var OIDCAuthEndpoint: String?
    public var OIDCTokenEndpoint: String?
    
    // Used for PKCE, no need to be public
    
    var codeVerifier = (UUID.init().uuidString + UUID.init().uuidString)
    
    // URL Session bits, we make a new ephemeral session every time the class
    // is invoked to ensure no lingering cookies
    
    var dataTask: URLSessionDataTask?
    var session = URLSession(configuration: URLSessionConfiguration.ephemeral, delegate: nil, delegateQueue: nil)
    
    // delegate for callbacks
    
    public var delegate: OIDCLiteDelegate?

    private var state: String?
    private let queryItemKeys = OIDCQueryItemKeys()
    
    private struct OIDCQueryItemKeys {
        let clientId = "client_id"
        let responseType = "response_type"
        let scope = "scope"
        let redirectUri = "redirect_uri"
        let state = "state"
        let codeChallengeMethod = "code_challenge_method"
        let codeChallenge = "code_challenge"
        let nonce = "nonce"
    }
    
    /// Create a new OIDCLite object
    /// - Parameters:
    ///   - discoveryURL: the well-known openid-configuration URL, e.g. https://my.idp.com/.well-known/openid-configuration
    ///   - clientID: the OpenID Connect client ID to be used
    ///   - clientSecret: optional OpenID Connect client secret
    ///   - redirectURI: optional redirect URI, can not be http or https. Defaults to "oidclite://openID" if nothing is supplied
    ///   - scopes: optional custom scopes to be used in the OpenID Connect request. If nothing is supplied ["openid", "profile", "email", "offline_access"] will be used
    ///
    public init(discoveryURL: String, clientID: String, clientSecret: String?, redirectURI: String?, scopes: [String]?) {
        self.discoveryURL = discoveryURL
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectURI = redirectURI ?? kRedirectURI
        self.scopes = scopes ?? kDefaultScopes
    }
    
    /// Generates the inital login URL which can be passed to ASWebAuthenticationSession
    /// - Returns: A URL to be used with ASWebAuthenticationSession
    public func createLoginURL() -> URL? {
        state = UUID().uuidString
        
        var queryItems: [URLQueryItem] = []
        
        let clientIdItem = URLQueryItem(name: queryItemKeys.clientId, value: clientID)
        queryItems.append(clientIdItem)
        
        let responseTypeItem: URLQueryItem
        let scopeItem: URLQueryItem
        
        responseTypeItem = URLQueryItem(name: queryItemKeys.responseType, value: "code")
        scopeItem = URLQueryItem(name: queryItemKeys.scope, value: scopes.joined(separator: " "))

        queryItems.append(contentsOf: [responseTypeItem, scopeItem])
        
        let redirectUriItem = URLQueryItem(name: queryItemKeys.redirectUri, value: redirectURI)
        queryItems.append(redirectUriItem)
        let stateItem = URLQueryItem(name: queryItemKeys.state, value: state)
        queryItems.append(stateItem)
        
        if let challengeData = codeVerifier.data(using: String.Encoding.ascii) {
            let codeChallengeMethodItem = URLQueryItem(name: queryItemKeys.codeChallengeMethod, value: "S256")
            let hash = SHA256.hash(data: challengeData)
            let challengeData = Data(hash)
            let challengeString = challengeData.base64EncodedString().base64URLEncoded()
            let codeChallengeItem = URLQueryItem(name: queryItemKeys.codeChallenge, value: challengeString)
            queryItems.append(contentsOf: [codeChallengeMethodItem, codeChallengeItem])
        }
        
        let nonceItem = URLQueryItem(name: queryItemKeys.nonce, value: UUID().uuidString)
        queryItems.append(nonceItem)
        
        guard let url = URL(string: OIDCAuthEndpoint ?? "") else {
            return nil
        }
        
        var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)
        urlComponents?.queryItems = queryItems
        return urlComponents?.url
    }
    
    /// Turn a code, returned from a successful ASWebAuthenticationSession, into a token set
    /// - Parameter code: the code generated by a successful authentication
    public func getToken(code: String) {
        
        guard let path = OIDCTokenEndpoint else {
            delegate?.authFailure(message: "No token endpoint found")
            return
        }
        
        guard let tokenURL = URL(string: path) else {
            delegate?.authFailure(message: "Unable to make the token endpoint into a URL")
            return
        }
        
        var body = "grant_type=authorization_code"
        
        body.append("&client_id=" + clientID)
        
        if let secret = clientSecret {
            body.append("&client_secret=" + secret )
        }
        
        body.append("&redirect_uri=" + redirectURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)
        let codeParam = "&code=" + code
        
        body.append(codeParam)
        body.append("&code_verifier=" + codeVerifier)
        
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.httpBody = body.data(using: .utf8)
        
        let headers = [
            "Accept": "application/json",
            "Content-Type": "application/x-www-form-urlencoded"
        ]
        
        req.allHTTPHeaderFields = headers
        
        dataTask = URLSession.shared.dataTask(with: req) { data, response, error in
            
            if let error = error {
                self.delegate?.authFailure(message: error.localizedDescription)
                
            } else if let data = data,
                let response = response as? HTTPURLResponse,
                response.statusCode == 200 {
                var tokenResponse = OIDCLiteTokenResponse()
                do {
                    let jsonResult = try JSONSerialization.jsonObject(with: data, options: JSONSerialization.ReadingOptions.mutableContainers) as? Dictionary<String, Any>
                    
                    if let accessToken = jsonResult?["access_token"] as? String {
                        tokenResponse.accessToken = accessToken
                    }
                    
                    if let refreshToken = jsonResult?["refresh_token"] as? String {
                        tokenResponse.refreshToken = refreshToken
                    }
                    
                    if let idToken = jsonResult?["id_token"] as? String {
                        tokenResponse.idToken = idToken
                    }
                        
                    self.delegate?.tokenResponse(tokens: tokenResponse)
                } catch {
                    self.delegate?.authFailure(message: "Unable to decode response")
                }
            } else {
                if data != nil {
                    do {
                        let jsonResult = try JSONSerialization.jsonObject(with: data!, options: JSONSerialization.ReadingOptions.mutableContainers) as? Dictionary<String, Any>
                        print(jsonResult as Any)
                    } catch {
                        print("No data")
                    }
                }
                self.delegate?.authFailure(message: response.debugDescription)
            }
        }
        dataTask?.resume()
    }
    
    /// Private function to parse the openid-configuration file into all of the requisite endpoints
    private func getEndpoints() {
        
        // make sure we can actually make a URL from the discoveryURL that we have
        guard let host = URL(string: discoveryURL) else { return }
        
        var dataTask: URLSessionDataTask?
        var req = URLRequest(url: host)
        let sema = DispatchSemaphore(value: 0)
        
        let headers = [
            "Accept": "application/json",
            "Cache-Control": "no-cache",
        ]
        
        req.allHTTPHeaderFields = headers
        req.httpMethod = "GET"
        
        dataTask = session.dataTask(with: req) { data, response, error in
            
            if let error = error {
                print(error.localizedDescription)
            } else if let data = data,
                let response = response as? HTTPURLResponse,
                response.statusCode == 200 {
                
                // if we got a 200 find the auth and token endpoints
                
                if let json = try? JSONSerialization.jsonObject(with: data) as? [ String : Any] {
                        self.OIDCAuthEndpoint = json["authorization_endpoint"] as? String ?? ""
                        self.OIDCTokenEndpoint = json["token_endpoint"] as? String ?? ""
                    }
                }
            sema.signal()
        }
        
        dataTask?.resume()
        sema.wait()
    }
}
