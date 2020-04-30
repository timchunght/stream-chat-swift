//
//  Client+DevicesTests.swift
//  StreamChatClientTests
//
//  Copyright © 2020 Stream.io Inc. All rights reserved.
//

import XCTest

@testable import StreamChatClient

class Client_DevicesTests: XCTestCase {

    // Ideally, we would create a new client for every test case. Unfortunately, this is not technically
    // possible at the moment.
    lazy var client: Client = {
        let sessionConfig = URLSessionConfiguration.default

        sessionConfig.protocolClasses?.insert(RequestRecorderURLProtocol.self, at: 0)
        Client.config = .init(apiKey: "test_api_key", defaultURLSessionConfiguration: sessionConfig)
        return Client.shared
    }()

    func test_getDevice_createsRequest() {
        // Setup
        let testUser = User(id: "test_user_\(UUID())")
        client.set(user: testUser, token: "test_token")

        // Action
        client.devices { _ in }

        // Assert
        AssertNetworkRequest(
            method: .get,
            path: "/devices",
            headers: ["Content-Type": "application/json"],
            queryParameters: ["api_key": "test_api_key"],
            body: nil
        )
    }

    func test_addDevice_withDeviceID_createsRequest() {
        // Setup
        let testUser = User(id: "test_user_\(UUID())")
        let testDeviceId = "device_id_\(UUID())"
        client.set(user: testUser, token: "test_token")

        // Action
        client.addDevice(deviceId: testDeviceId)

        // Assert
        AssertNetworkRequest(
            method: .post,
            path: "/devices",
            headers: ["Content-Type": "application/json", "Content-Encoding": "gzip"],
            queryParameters: ["api_key": "test_api_key"],
            body: [
                "user_id": testUser.id,
                "id": testDeviceId,
                "push_provider": "apn",
            ]
        )
    }

    func test_addDevice_withDeviceToken_createsRequest() {
        // Setup
        let testUser = User(id: "test_user_\(UUID())")
        let deviceToken = Data([1, 2, 3, 4])
        client.set(user: testUser, token: "test_token")

        // Action
        client.addDevice(deviceToken: deviceToken)

        // Assert
        AssertNetworkRequest(
            method: .post,
            path: "/devices",
            headers: ["Content-Type": "application/json", "Content-Encoding": "gzip"],
            queryParameters: ["api_key": "test_api_key"],
            body: [
                "user_id": testUser.id,
                "id": "01020304", // the hexadecimal representation of the data
                "push_provider": "apn",
            ]
        )
    }

    func test_removeDevice_createsRequest() {
        // Setup
        let testUser = User(id: "test_user_\(UUID())")
        let testDeviceId = "device_id_\(UUID())"
        client.set(user: testUser, token: "test_token")

        // Action
        client.removeDevice(deviceId: testDeviceId)

        // Assert
        AssertNetworkRequest(
            method: .delete,
            path: "/devices",
            headers: ["Content-Type": "application/json"],
            queryParameters: [
                "api_key": "test_api_key",
                "id": testDeviceId,
            ],
            body: nil
        )
    }
}
