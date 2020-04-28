//
//  Client+Coders.swift
//  StreamChatClient
//
//  Created by Vojta on 28/04/2020.
//  Copyright © 2020 Stream.io Inc. All rights reserved.
//

import Foundation

extension Client {

    enum DecoderError: Error {
        /// You must use `ClientAwareJSONDecoder` to decode this object.
        case unsupportedDecoder
    }

    /// This is just a temporary solution (hack) to get the client instance
    /// into the objects we decode.
    class ClientAwareJSONDecoder: JSONDecoder {

        unowned let client: Client

        init(client: Client) {
            self.client = client
            super.init()

            dateDecodingStrategy = .custom { decoder throws -> Date in
                let container = try decoder.singleValueContainer()
                var dateString: String = try container.decode(String.self)

                if !dateString.contains(".") {
                    dateString.removeLast()
                    dateString.append(".0Z")
                }

                if let date = DateFormatter.Stream.iso8601Date(from: dateString) {
                    return date
                }

                if dateString.hasPrefix("1970-01-01T00:00:00") {
                    print("⚠️ Invalid ISO8601 date: \(dateString)")
                    return Date()
                }

                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(dateString)")
            }
        }
    }

}
