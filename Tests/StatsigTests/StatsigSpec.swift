import Foundation

import Nimble
import OHHTTPStubs
import Quick

#if !COCOAPODS
import OHHTTPStubsSwift
#endif

@testable import Statsig
import SwiftUI

class StatsigSpec: QuickSpec {
    static let mockUserValues: [String: Any] = [
        "feature_gates": [
            "gate_name_1".sha256(): [
                "value": false,
                "rule_id": "rule_id_1",
                "secondary_exposures": [
                    ["gate": "employee", "gateValue": "true", "ruleID": "rule_id_employee"]
                ]
            ],
            "gate_name_2".sha256(): ["value": true, "rule_id": "rule_id_2"]
        ],
        "dynamic_configs": [
            "config".sha256(): DynamicConfigSpec.TestMixedConfig
        ]
    ]

    override func spec() {
        describe("starting Statsig") {
            beforeEach {
                InternalStore.deleteAllLocalStorage()
            }

            afterEach {
                HTTPStubs.removeAllStubs()
                Statsig.shutdown()
                InternalStore.deleteAllLocalStorage()
            }

            context("when starting with invalid SDK keys") {
                it("works when provided invalid SDK key by returning default value") {
                    stub(condition: isHost("api.statsig.com")) { _ in
                        let notConnectedError = NSError(domain: NSURLErrorDomain, code: 403)
                        return HTTPStubsResponse(error: notConnectedError)
                    }

                    var error: String?
                    var gate: Bool?
                    var config: DynamicConfig?
                    waitUntil { done in
                        Statsig.start(sdkKey: "invalid_sdk_key", options: StatsigOptions()) { errorMessage in
                            error = errorMessage
                            gate = Statsig.checkGate("show_coupon")
                            config = Statsig.getConfig("my_config")
                            done()
                        }
                    }

                    expect(error).toEventually(contain("403"))
                    expect(gate).toEventually(beFalse())
                    expect(NSDictionary(dictionary: config!.value)).toEventually(equal(NSDictionary(dictionary: [:])))
                }

                it("works when provided server secret by returning default value") {
                    var error: String?
                    var gate: Bool?
                    var config: DynamicConfig?
                    Statsig.start(sdkKey: "secret-key") { errorMessage in
                        error = errorMessage
                        gate = Statsig.checkGate("show_coupon")
                        config = Statsig.getConfig("my_config")
                    }
                    expect(error).toEventually(equal("Must use a valid client SDK key."))
                    expect(gate).toEventually(beFalse())
                    expect(NSDictionary(dictionary: config!.value)).toEventually(equal(NSDictionary(dictionary: [:])))
                }
            }

            context("when starting Statsig with valid SDK keys") {
                let gateName1 = "gate_name_1"
                let gateName2 = "gate_name_2"
                let nonExistentGateName = "gate_name_3"

                let configName = "config"
                let nonExistentConfigName = "non_existent_config"

                it("only makes 1 network request if start() is called multiple times") {
                    var requestCount = 0
                    stub(condition: isHost("api.statsig.com")) { _ in
                        requestCount += 1
                        return HTTPStubsResponse(jsonObject: [:], statusCode: 200, headers: nil)
                    }

                    Statsig.start(sdkKey: "client-api-key")
                    Statsig.start(sdkKey: "client-api-key")
                    Statsig.start(sdkKey: "client-api-key")

                    expect(requestCount).toEventually(equal(1))
                }

                it("make only 1 network request in 11 seconds when enableAutoValueUpdate is not set to true") {
                    var requestCount = 0
                    var lastSyncTime: Double = 0
                    let now = NSDate().timeIntervalSince1970

                    stub(condition: isHost("api.statsig.com")) { request in
                        requestCount += 1

                        let httpBody = try! JSONSerialization.jsonObject(
                            with: request.ohhttpStubs_httpBody!,
                            options: []) as! [String: Any]
                        lastSyncTime = httpBody["lastSyncTimeForUser"] as? Double ?? 0

                        return HTTPStubsResponse(jsonObject: ["time": now * 1000], statusCode: 200, headers: nil)
                    }

                    Statsig.start(sdkKey: "client-api-key")

                    // first request, "lastSyncTimeForUser" field should not be present in the request body
                    expect(requestCount).toEventually(equal(1), timeout: .seconds(11))
                    expect(lastSyncTime).to(equal(0))
                }

                it("makes 2 network requests in 11 seconds and updates internal store's updatedTime correctly each time when enableAutoValueUpdate is true") {
                    var requestCount = 0
                    var lastSyncTime: Double = 0
                    let now = NSDate().timeIntervalSince1970

                    stub(condition: isHost("api.statsig.com")) { request in
                        requestCount += 1

                        let httpBody = try! JSONSerialization.jsonObject(
                            with: request.ohhttpStubs_httpBody!,
                            options: []) as! [String: Any]
                        lastSyncTime = httpBody["lastSyncTimeForUser"] as? Double ?? 0

                        return HTTPStubsResponse(jsonObject: ["time": now * 1000], statusCode: 200, headers: nil)
                    }

                    Statsig.start(sdkKey: "client-api-key", options: StatsigOptions(enableAutoValueUpdate: true))

                    // first request, "lastSyncTimeForUser" field should not be present in the request body
                    expect(requestCount).toEventually(equal(1), timeout: .seconds(1))
                    expect(lastSyncTime).to(equal(0))

                    // second request, "lastSyncTimeForUser" field should be the time when the first request was sent
                    expect(requestCount).toEventually(equal(2), timeout: .seconds(11))
                    expect(Int(lastSyncTime / 1000)).toEventually(equal(Int(now)), timeout: .seconds(11))
                }

                it("works with local cache with different user cache keys") {
                    stub(condition: isHost("api.statsig.com")) { _ in
                        HTTPStubsResponse(jsonObject: StatsigSpec.mockUserValues, statusCode: 200, headers: nil)
                    }

                    let gateName = "gate_name_2"

                    waitUntil { done in
                        Statsig.start(sdkKey: "client-api-key", user: StatsigUser(userID: "jkw")) { _ in
                            done()
                        }
                    }

                    // gate should be true, using network response;
                    expect(Statsig.checkGate(gateName)).to(beTrue())

                    // the values are now cached for the first user. Now test when network is not available, and cache for the first user should NOT be used
                    stub(condition: isHost("api.statsig.com")) { _ in
                        let notConnectedError = NSError(domain: NSURLErrorDomain, code: 403)
                        return HTTPStubsResponse(error: notConnectedError)
                    }

                    waitUntil { done in
                        Statsig.updateUser(StatsigUser(userID: "jkw", customIDs: ["companyID": "statsig"])) { _ in
                            done()
                        }
                    }
                    // should only return the default value, because cache key, which uses userID AND customIDs, have changed
                    expect(Statsig.checkGate(gateName)).to(beFalse())

                    waitUntil { done in
                        Statsig.updateUser(StatsigUser()) { _ in
                            done()
                        }
                    }
                    expect(Statsig.checkGate(gateName)).to(beFalse())

                    // back to the original user, cache should now be used
                    waitUntil { done in
                        Statsig.updateUser(StatsigUser(userID: "jkw")) { _ in
                            done()
                        }
                    }
                    expect(Statsig.checkGate(gateName)).to(beTrue())
                }

                it("works correctly with a valid JSON response") {
                    stub(condition: isHost("api.statsig.com")) { _ in
                        HTTPStubsResponse(jsonObject: StatsigSpec.mockUserValues, statusCode: 200, headers: nil)
                    }

                    var gate1: Bool?
                    var gate2: Bool?
                    var nonExistentGate: Bool?
                    var dc: DynamicConfig?
                    var exp: DynamicConfig?
                    var nonExistentDC: DynamicConfig?

                    waitUntil { done in
                        Statsig.start(sdkKey: "client-api-key") { _ in
                            gate1 = Statsig.checkGate(gateName1)
                            gate2 = Statsig.checkGate(gateName2)
                            nonExistentGate = Statsig.checkGate(nonExistentGateName)

                            dc = Statsig.getConfig(configName)
                            exp = Statsig.getExperiment(configName)
                            nonExistentDC = Statsig.getConfig(nonExistentConfigName)

                            done()
                        }
                    }


                    expect(gate1).toEventually(beFalse())
                    expect(gate2).toEventually(beTrue())
                    expect(nonExistentGate).toEventually(beFalse())

                    expect(NSDictionary(dictionary: dc!.value)).toEventually(
                        equal(NSDictionary(dictionary: DynamicConfigSpec.TestMixedConfig["value"] as! [String: Any])))
                    expect(NSDictionary(dictionary: exp!.value)).toEventually(
                        equal(NSDictionary(dictionary: DynamicConfigSpec.TestMixedConfig["value"] as! [String: Any])))
                    expect(NSDictionary(dictionary: nonExistentDC!.value)).toEventually(equal(NSDictionary(dictionary: [:])))

                    // Now add overrides on top and check if they work
                    Statsig.overrideGate(gateName1, value: true)
                    expect(Statsig.checkGate(gateName1)).to(beTrue())

                    Statsig.overrideGate(gateName1, value: false)
                    expect(Statsig.checkGate(gateName1)).to(beFalse())

                    Statsig.overrideGate("gate_fake", value: true)
                    expect(Statsig.checkGate("gate_fake")).to(beTrue())

                    Statsig.overrideConfig(configName, value: ["param": "value"])
                    expect(Statsig.getConfig(configName).getValue(forKey: "param", defaultValue: "wrong")).to(equal("value"))
                    expect(Statsig.getExperiment(configName).getValue(forKey: "param", defaultValue: "wrong")).to(equal("value"))

                    var overrides = Statsig.getAllOverrides()
                    expect(overrides?.gates.keys.count).to(equal(2))
                    expect(overrides?.gates[gateName1]).to(beFalse())
                    expect(overrides?.gates["gate_fake"]).to(beTrue())

                    expect(overrides?.configs.keys.count).to(equal(1))
                    expect(NSDictionary(dictionary: overrides!.configs[configName]!)).to(equal(NSDictionary(dictionary: ["param": "value"])))

                    Statsig.removeOverride(gateName1)
                    expect(Statsig.checkGate(gateName1)).to(beFalse())

                    Statsig.removeOverride(configName)
                    expect(NSDictionary(dictionary: Statsig.getConfig(configName).value)).to(
                        equal(NSDictionary(dictionary: DynamicConfigSpec.TestMixedConfig["value"] as! [String: Any])))

                    overrides = Statsig.getAllOverrides()
                    expect(overrides?.gates.keys.count).to(equal(1))
                    expect(overrides?.configs.keys.count).to(equal(0))

                    Statsig.removeAllOverrides()
                    overrides = Statsig.getAllOverrides()
                    expect(overrides?.gates.keys.count).to(equal(0))
                    expect(overrides?.configs.keys.count).to(equal(0))
                }

                it("times out if the request took too long and responds early with default values, when there is no local cache") {
                    stub(condition: isHost("api.statsig.com")) { _ in
                        HTTPStubsResponse(jsonObject: StatsigSpec.mockUserValues, statusCode: 200, headers: nil)
                            .responseTime(4.0)
                    }

                    var error: String?
                    var gate: Bool?
                    var dc: DynamicConfig?
                    let timeBefore = NSDate().timeIntervalSince1970
                    var timeDiff: TimeInterval? = 0

                    Statsig.start(sdkKey: "client-api-key") { errorMessage in
                        error = errorMessage
                        gate = Statsig.checkGate(gateName2)
                        dc = Statsig.getConfig(configName)
                        timeDiff = NSDate().timeIntervalSince1970 - timeBefore
                    }

                    // check the values immediately following the completion block from start() assignments
                    expect(error).toEventually(beNil(), timeout: .milliseconds(3500))
                    expect(gate).toEventually(beFalse(), timeout: .milliseconds(3500))
                    expect(NSDictionary(dictionary: dc!.value)).toEventually(equal(NSDictionary(dictionary: [:])), timeout: .milliseconds(3500))
                    expect(Int(timeDiff!)).toEventually(equal(3), timeout: .milliseconds(3500))

                    // check the same gate and config >4 seconds later should return the results from response JSON
                    expect(Statsig.checkGate(gateName2)).toEventually(beTrue(), timeout: .milliseconds(4500))
                    expect(Statsig.getConfig(configName)).toEventuallyNot(beNil(), timeout: .milliseconds(4500))
                }

                it("times out and returns value from local cache") {
                    stub(condition: isHost("api.statsig.com")) { _ in
                        HTTPStubsResponse(jsonObject: StatsigSpec.mockUserValues, statusCode: 200, headers: nil)
                    }

                    var gate: Bool?
                    var nonExistentGate: Bool?
                    var dc: DynamicConfig?
                    var exp: DynamicConfig?
                    var nonExistentDC: DynamicConfig?

                    // First call start() to fetch and store values in local storage
                    Statsig.start(sdkKey: "client-api-key") { _ in
                        // shutdown client to call start() again, and makes response slow so we can test early timeout with cached return
                        Statsig.shutdown()
                        stub(condition: isHost("api.statsig.com")) { _ in
                            HTTPStubsResponse(jsonObject: StatsigSpec.mockUserValues, statusCode: 200, headers: nil).responseTime(3)
                        }

                        Statsig.start(sdkKey: "client-api-key", options: StatsigOptions(initTimeout: 0.1)) { _ in
                            gate = Statsig.checkGate(gateName2)
                            nonExistentGate = Statsig.checkGate(nonExistentGateName)
                            dc = Statsig.getConfig(configName)
                            exp = Statsig.getExperiment(configName)
                            nonExistentDC = Statsig.getConfig(nonExistentConfigName)
                        }
                    }

                    expect(gate).toEventually(beTrue())
                    expect(nonExistentGate).toEventually(beFalse())
                    expect(dc).toEventuallyNot(beNil())
                    expect(exp).toEventuallyNot(beNil())
                    expect(NSDictionary(dictionary: nonExistentDC!.value)).toEventually(equal(NSDictionary(dictionary: [:])))
                }

                it("correctly shuts down") {
                    stub(condition: isPath("/v1/initialize")) { _ in
                        HTTPStubsResponse(jsonObject: StatsigSpec.mockUserValues, statusCode: 200, headers: nil)
                    }

                    var events: [[String: Any]] = []
                    var statsigMetadata: [String: String?] = [:]
                    stub(condition: isPath("/v1/rgstr")) { request in
                        let actualRequestHttpBody = try! JSONSerialization.jsonObject(
                            with: request.ohhttpStubs_httpBody!,
                            options: []) as! [String: Any]
                        events = actualRequestHttpBody["events"] as! [[String: Any]]
                        statsigMetadata = actualRequestHttpBody["statsigMetadata"] as! [String: String?]
                        return HTTPStubsResponse(jsonObject: StatsigSpec.mockUserValues, statusCode: 200, headers: nil)
                    }

                    var gate: Bool?
                    var config: DynamicConfig?
                    var exp: DynamicConfig?
                    var stableID: String?
                    waitUntil { done in
                        Statsig.start(sdkKey: "client-api-key",
                                      user: StatsigUser(userID: "123", email: "123@statsig.com"),
                                      options: StatsigOptions(overrideStableID: "custom_stable_id"))
                        { _ in
                            gate = Statsig.checkGate(gateName2)
                            Statsig.checkGate(gateName2) // should not create an exposure, deduped
                            exp = Statsig.getExperiment(configName)
                            config = Statsig.getConfig(configName) // should not create an exposure, deduped
                            stableID = Statsig.getStableID()
                            Statsig.logEvent("test_event", value: 1, metadata: ["key": "value1"])
                            Statsig.logEvent("test_event_2", value: "1", metadata: ["key": "value2"])
                            Statsig.logEvent("test_event_3", metadata: ["key": "value3"])
                            Statsig.updateUser(StatsigUser(userID: "123", email: "123@statsig.com")) { errorMessage in
                                Statsig.checkGate(gateName2) // should create an exposure, no longer dedupe after updating user
                                Statsig.shutdown()
                                done()
                            }
                        }
                    }

                    expect(gate).to(beTrue())
                    expect(NSDictionary(dictionary: config!.value)).to(
                        equal(
                            NSDictionary(dictionary: DynamicConfigSpec.TestMixedConfig["value"] as! [String: Any])
                        )
                    )
                    expect(NSDictionary(dictionary: exp!.value)).to(
                        equal(
                            NSDictionary(dictionary: DynamicConfigSpec.TestMixedConfig["value"] as! [String: Any])
                        )
                    )

                    expect(events.count).toEventually(equal(6))

                    var event = events[0]
                    var user = event["user"] as! [String: Any]
                    var metadata = event["metadata"] as! [String: String]?
                    var secondaryExposures = event["secondaryExposures"] as! [[String: String]]?
                    var value = event["value"]

                    expect(event["eventName"] as? String).to(equal(Event.statsigPrefix + Event.gateExposureEventName))
                    expect(user["userID"] as? String).to(equal("123"))
                    expect(user["email"] as? String).to(equal("123@statsig.com"))
                    expect(NSDictionary(dictionary: metadata!)).to(equal(NSDictionary(dictionary: ["gate": "gate_name_2", "gateValue": "true", "ruleID": "rule_id_2"])))
                    expect(secondaryExposures).to(equal([]))
                    expect(value).to(beNil())

                    event = events[1]
                    user = event["user"] as! [String: Any]
                    metadata = event["metadata"] as! [String: String]?
                    secondaryExposures = event["secondaryExposures"] as! [[String: String]]?
                    value = event["value"]

                    expect(event["eventName"] as? String).to(equal(Event.statsigPrefix + Event.configExposureEventName))
                    expect(user["userID"] as? String).to(equal("123"))
                    expect(user["email"] as? String).to(equal("123@statsig.com"))
                    expect(NSDictionary(dictionary: metadata!)).to(equal(NSDictionary(dictionary: ["config": "config", "ruleID": "default"])))
                    expect(secondaryExposures).to(equal([]))
                    expect(value).to(beNil())

                    event = events[2]
                    user = event["user"] as! [String: Any]
                    metadata = event["metadata"] as! [String: String]?
                    secondaryExposures = event["secondaryExposures"] as! [[String: String]]?
                    value = event["value"]

                    expect(event["eventName"] as? String).to(equal("test_event"))
                    expect(user["userID"] as? String).to(equal("123"))
                    expect(user["email"] as? String).to(equal("123@statsig.com"))
                    expect(NSDictionary(dictionary: metadata!)).to(equal(NSDictionary(dictionary: ["key": "value1"])))
                    expect(secondaryExposures).to(beNil())
                    expect(value as? Int).to(equal(1))

                    event = events[3]
                    user = event["user"] as! [String: Any]
                    metadata = event["metadata"] as! [String: String]?
                    secondaryExposures = event["secondaryExposures"] as! [[String: String]]?
                    value = event["value"]

                    expect(event["eventName"] as? String).to(equal("test_event_2"))
                    expect(user["userID"] as? String).to(equal("123"))
                    expect(user["email"] as? String).to(equal("123@statsig.com"))
                    expect(NSDictionary(dictionary: metadata!)).to(equal(NSDictionary(dictionary: ["key": "value2"])))
                    expect(secondaryExposures).to(beNil())
                    expect(value as? String).to(equal("1"))

                    event = events[4]
                    user = event["user"] as! [String: Any]
                    metadata = event["metadata"] as! [String: String]?
                    secondaryExposures = event["secondaryExposures"] as! [[String: String]]?
                    value = event["value"]

                    expect(event["eventName"] as? String).to(equal("test_event_3"))
                    expect(user["userID"] as? String).to(equal("123"))
                    expect(user["email"] as? String).to(equal("123@statsig.com"))
                    expect(NSDictionary(dictionary: metadata!)).to(equal(NSDictionary(dictionary: ["key": "value3"])))
                    expect(secondaryExposures).to(beNil())
                    expect(value).to(beNil())

                    event = events[5]
                    user = event["user"] as! [String: Any]
                    metadata = event["metadata"] as! [String: String]?
                    secondaryExposures = event["secondaryExposures"] as! [[String: String]]?
                    value = event["value"]

                    expect(event["eventName"] as? String).to(equal(Event.statsigPrefix + Event.gateExposureEventName))
                    expect(user["userID"] as? String).to(equal("123"))
                    expect(user["email"] as? String).to(equal("123@statsig.com"))
                    expect(NSDictionary(dictionary: metadata!)).to(equal(NSDictionary(dictionary: ["gate": "gate_name_2", "gateValue": "true", "ruleID": "rule_id_2"])))
                    expect(secondaryExposures).to(equal([]))
                    expect(value).to(beNil())

                    // validate stable ID
                    expect(statsigMetadata["stableID"]).to(equal("custom_stable_id"))
                    expect(stableID).to(equal("custom_stable_id"))
                }
            }

            describe("handling null") {
                stub(condition: isPath("/v1/initialize")) { _ in
                    var mock = StatsigSpec.mockUserValues
                    mock[jsonDict: "dynamic_configs"]?["null_value_config".sha256()] = [
                        "rule_id": "default",
                        "value":
                            [
                                "str": "string",
                                "null": nil
                            ]
                    ]

                    return HTTPStubsResponse(jsonObject: mock, statusCode: 200, headers: nil)
                }

                it("works when initialize contains null") {
                    waitUntil { done in
                        Statsig.start(sdkKey: "client-api-key") { _ in
                            let config = Statsig.getConfig("null_value_config")

                            let defaultVal = config.getValue(forKey: "null", defaultValue: "default")
                            expect(defaultVal).to(equal("default"))
                            done()
                        }
                    }
                }

                it("works when override contains null") {
                    waitUntil { done in
                        Statsig.start(sdkKey: "client-api-key") { _ in

                            let dict = ["foo": nil] as [String : Any?]
                            Statsig.overrideConfig("config", value: dict as [String: Any])

                            Statsig.start(sdkKey: "client-api-key") { _ in
                                let config = Statsig.getConfig("config")

                                let defaultVal = config.getValue(forKey: "foo", defaultValue: "default")
                                expect(defaultVal).to(equal("default"))
                                done()
                            }
                        }
                    }
                }
            }
        }
    }
}
