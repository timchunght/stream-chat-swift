//
//  Client.swift
//  StreamChatCore
//
//  Created by Alexey Bukhtin on 01/04/2019.
//  Copyright © 2019 Stream.io Inc. All rights reserved.
//

import UIKit

/// A network client.
public final class Client: Uploader {
    /// A client completion block type.
    public typealias Completion<T: Decodable> = (Result<T, ClientError>) -> Void
    /// A client progress block type.
    public typealias Progress = (Float) -> Void
    /// A WebSocket events callback type.
    public typealias OnEvent = (Event) -> Void
    
    /// A client config (see `Config`).
    @available(*, deprecated, message: """
    Configuring the shared Client using the static `Client.config` variable has been depreacted. Please create an instance
    of the `Client.Config` struct and call `Client.configure(_:)` to set up the shared instance of Client.
    """)
    public static var config: Config {
        get { config_backwardCompatibility }
        set { config_backwardCompatibility = newValue }
    }
    /// We need this value to avoid deprecation warnings when keeping backward compatibility. This can be removed
    /// once we remove the deprecated methods completely.
    private static var config_backwardCompatibility = Config(apiKey: "")

    /// Configures the shared instance of `Client`.
    ///
    /// - Parameter configuration: The configuration object with details of how the shared instance should be set up.
    ///
    public static func configure(_ configuration: Config) {
        sharedClientFactory = { Client(configuration: configuration) }
    }

    /// A shared client.
    public private(set) static var shared: Client = sharedClientFactory()

    private static var sharedClientFactory: () -> Client = {
        // This closure is here only for backward compatibility. Only uses who haven't called `Client.configute(_:)`
        // see the warning below and the shared client in initialized the old way.
        //
        // Calling `Client.configute(_:)` replaces this factory closure and uses the new way of
        // the initialization of the shared client.

        ClientLogger.logger("⚠️", "", "Configuring the shared Client using the static `Client.config` variable " +
            "has been depreacted. Please create an instance of the `Client.Config` struct and call `Client.configure(_:)` " +
            "to set up the shared instance of Client."
        )
        return Client(configuration: Client.config_backwardCompatibility)
    }
    
    /// Stream API key.
    /// - Note: If you will change API key the Client will be disconnected and the current user will be logged out.
    ///         You have to setup another user after that.
    public var apiKey: String {
        didSet {
            checkAPIKey()
            disconnect()
        }
    }
    
    /// A base URL.
    public let baseURL: BaseURL
    let stayConnectedInBackground: Bool
    /// A database for an offline mode.
    public internal(set) var database: Database?
    
    /// A log manager.
    public let logger: ClientLogger?
    public let logOptions: ClientLogger.Options
    
    // MARK: Token
    
    var token: Token?
    var tokenProvider: TokenProvider?
    /// Checks if the expired Token is updating.
    public internal(set) var isExpiredTokenInProgress = false // FIXME: Should be internal.
    var waitingRequests = [WaitingRequest]()
    
    // MARK: WebSocket
    
    /// A web socket client.
    lazy var webSocket = WebSocket()
    /// Check if API key and token are valid and the web socket is connected.
    public var isConnected: Bool { !apiKey.isEmpty && webSocket.isConnected }
    var needsToRecoverConnection = false
    
    lazy var urlSession = URLSession(configuration: .default)
    lazy var urlSessionTaskDelegate = ClientURLSessionTaskDelegate() // swiftlint:disable:this weak_delegate
    let callbackQueue: DispatchQueue?
    
    private(set) lazy var eventsHandlingQueue = DispatchQueue(label: "io.getstream.Chat.clientEvents", qos: .userInteractive)
    let subscriptionBag = SubscriptionBag()
    
    // MARK: User Events
    
    /// The current user.
    public var user: User { userAtomic.get() ?? .unknown }
    
    var onUserUpdateObservers = [String: OnUpdate<User>]()
    
    private(set) lazy var userAtomic = Atomic<User>(callbackQueue: eventsHandlingQueue) { [unowned self] newUser, _ in
        if let user = newUser {
            self.onUserUpdateObservers.values.forEach({ $0(user) })
        }
    }
    
    // MARK: Unread Count Events
    
    /// Channels and messages unread counts.
    public var unreadCount: UnreadCount { unreadCountAtomic.get(default: .noUnread) }
    var onUnreadCountUpdateObservers = [String: OnUpdate<UnreadCount>]()
    
    private(set) lazy var unreadCountAtomic = Atomic<UnreadCount>(.noUnread, callbackQueue: eventsHandlingQueue) { [unowned self] in
        if let unreadCount = $0, unreadCount != $1 {
            self.onUnreadCountUpdateObservers.values.forEach({ $0(unreadCount) })
        }
    }
    
    /// Weak references to channels by cid.
    let watchingChannelsAtomic = Atomic<[ChannelId: [WeakRef<Channel>]]>([:])
    
    /// Creates a new isntance of the network client.
    ///
    /// - Parameter configuration: The configuration object with details of how the new instance should be set up.
    ///
    init(configuration: Client.Config) {
        self.apiKey = configuration.apiKey
        self.baseURL = configuration.baseURL
        self.callbackQueue = configuration.callbackQueue ?? .global(qos: .userInitiated)
        self.stayConnectedInBackground = configuration.stayConnectedInBackground
        self.database = configuration.database
        self.logOptions = configuration.logOptions
        logger = logOptions.logger(icon: "🐴", for: [.requestsError, .requests, .requestsInfo])

        if !apiKey.isEmpty, logOptions.isEnabled {
            ClientLogger.logger("💬", "", "Stream Chat v.\(Environment.version)")
            ClientLogger.logger("🔑", "", apiKey)
            ClientLogger.logger("🔗", "", baseURL.description)
            
            if let database = database {
                ClientLogger.logger("💽", "", "\(database.self)")
            }
        }

        #if DEBUG
        checkLatestVersion()
        #endif
        checkAPIKey()
    }
    
    deinit {
        subscriptionBag.cancel()
    }
    
    private func checkAPIKey() {
        if apiKey.isEmpty {
            ClientLogger.logger("❌❌❌", "", "The Stream Chat Client didn't setup properly. "
                + "You are trying to use it before setting up the API Key. "
                + "Please use `Client.config = .init(apiKey:) to setup your api key. "
                + "You can debug this issue by putting a breakpoint in \(#file)\(#line)")
        }
    }
    
    /// Handle a connection with an application state.
    /// - Note:
    ///   - Skip if the Internet is not available.
    ///   - Skip if it's already connected.
    ///   - Skip if it's reconnecting.
    ///
    /// Application State:
    /// - `.active`
    ///   - `cancelBackgroundWork()`
    ///   - `connect()`
    /// - `.background` and `isConnected`
    ///   - `disconnectInBackground()`
    /// - Parameter appState: an application state.
    func connect(appState: UIApplication.State = UIApplication.shared.applicationState,
                 internetConnectionState: InternetConnection.State = InternetConnection.shared.state) {
        guard internetConnectionState == .available else {
            if internetConnectionState == .unavailable {
                reset()
            }
            
            return
        }
        
        if appState == .active {
            webSocket.connect()
        } else if appState == .background, webSocket.isConnected {
            webSocket.disconnectInBackground()
        }
    }
    
    /// Disconnect the web socket.
    public func disconnect() {
        logger?.log("Disconnecting deliberately...")
        reset()
        Application.shared.onStateChanged = nil
        InternetConnection.shared.stopNotifier()
    }
    
    /// Disconnect the websocket and reset states.
    func reset() {
        if webSocket.connectionId != nil {
            needsToRecoverConnection = true
        }
        
        webSocket.disconnect(reason: "Resetting connection")
        Message.flaggedIds.removeAll()
        User.flaggedUsers.removeAll()
        isExpiredTokenInProgress = false
        
        performInCallbackQueue { [unowned self] in
            self.waitingRequests.forEach { $0.cancel() }
            self.waitingRequests = []
        }
    }
    
    /// Checks if the given channel is watching.
    /// - Parameter channel: a channel.
    /// - Returns: returns true if the client is watching for the channel.
    public func isWatching(channel: Channel) -> Bool {
        let watchingChannels: [WeakRef<Channel>]? = watchingChannelsAtomic.get(default: [:])[channel.cid]
        return watchingChannels?.first { $0.value === channel } != nil
    }
}

// MARK: - Waiting Request

extension Client {
    final class WaitingRequest: Cancellable {
        typealias Request = () -> Cancellable // swiftlint:disable:this nesting
        
        private var subscription: Cancellable?
        private let request: Request
        
        init(request: @escaping Request) {
            self.request = request
        }
        
        func perform() {
            if subscription == nil {
                subscription = request()
            }
        }
        
        func cancel() {
            subscription?.cancel()
        }
    }
}
