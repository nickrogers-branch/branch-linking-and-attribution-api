//
//  AppDelegate.swift
//  Snowman
//
//  Created by Nick Rogers on 3/6/23.
//

import UIKit
import WebKit

class BranchHandler {
    /// The handler where deep link data is retutned after successful Branch initialization.
    var handler: (([AnyHashable: AnyObject]) -> Void)?
    /// Deep link data returned from the Branch API
    var latestReferringParams: [AnyHashable: AnyObject]?
    
    /// Singleton for this session
    static var shared = BranchHandler()
    
    /// The ID present when the app is launched from a URI scheme
    private var linkClickID: String?
    /// The web URL that represents a Universal Link when the app is launched from an Associated Domain
    private var universalLink: String?
    /// A boolean indicating whether the v1/open call has already been triggered
    private var openCallTriggered: Bool
    
    private init() {
        // When first initializing, ensure the boolean used for deciding if we need to make an open call is reset
        self.openCallTriggered = false
        
        // If no Universal Link or URI scheme has been triggered, ensure the v1/open request does get called.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.initiateBranchOpenRequest()
        }
    }
    
    // MARK: Lifecycle methods
    
    func continueUserActivity(_ userActivity: NSUserActivity) {
        // Handle the lifecycle method "continueUserActivity"
        // Extract the web URL from the NSUserActivity object
        
        if let webURL = userActivity.webpageURL {
            self.universalLink = webURL.absoluteString
            
            // We have a web URL, so initiate the v1/open request after saving that web URL
            initiateBranchOpenRequest()
        }
    }
    
    func openURL(_ url: URL) {
        // Check if the URL contains "link_click_id" query parameter on it. Note: The URL may be in a scheme format (e.g., "myapp://link?link_click_id=abc123", we want "abc123").
        
        // Parse the URL's query items
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryItems = components.queryItems {
            
            // Find the "link_click_id" query parameter
            if let linkClickID = queryItems.first(where: { $0.name == "link_click_id" })?.value {
                print("Extracted link_click_id: \(linkClickID)")
                
                // Save the link click ID for future use.
                self.linkClickID = linkClickID
                
                // We have a session opened from a URI scheme, so initiate the v1/open request
                initiateBranchOpenRequest()
            } else {
                print("link_click_id not found in the URL.")
            }
        } else {
            print("Invalid URL or no query items present.")
        }
    }
    
    func didEnterBackground() {
        // Reset the limiter for opens so that if the app is launched from a link, we'll make a new call to retrieve deep link data
        openCallTriggered = false
    }
    
    // MARK: Branch API calls
    
    private func initiateBranchOpenRequest() {
        // If we've already hit the open endpoint, don't do it again.
        if openCallTriggered {
            return
        } else {
            openCallTriggered = true
        }
        
        self.getUserAgent { userAgentString in
            DispatchQueue.global(qos: .userInteractive).async {
                var version: String?
                if let infoDictionary = Bundle.main.infoDictionary {
                    version = infoDictionary["CFBundleShortVersionString"] as? String
                }
                
                let osVersion = ProcessInfo.processInfo.operatingSystemVersion
                
                var requestBody: [String: Any] = [:]
                requestBody["server_to_server"] = true
                requestBody["os"] = "iOS"
                requestBody["is_hardware_id_real"] = true
                requestBody["ad_tracking_enabled"] = false
                    requestBody["branch_key"] = "YOUR BRANCH KEY HERE"
                    requestBody["branch_secret"] = "YOUR BRANCH SECRET HERE"
                
                if version != nil {
                    requestBody["app_version"] = version
                }
                requestBody["model"] = UIDevice.current.model
                requestBody["user_agent"] = userAgentString
                requestBody["os_version"] = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
                
                if let idfv = UIDevice.current.identifierForVendor {
                    requestBody["hardware_id"] = idfv.uuidString
                    requestBody["hardware_id_type"] = "vendor_id"
                    requestBody["ios_vendor_id"] = idfv.uuidString
                }
                
                if let universalLink = self.universalLink {
                    requestBody["universal_link_url"] = universalLink
                } else if let linkClickID = self.linkClickID {
                    requestBody["link_identifier"] = linkClickID
                }
                
                // Make the POST request
                guard let url = URL(string: "https://api2.branch.io/v1/open") else {
                    print("Invalid URL")
                    return
                }
                
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                
                do {
                    request.httpBody = try JSONSerialization.data(withJSONObject: requestBody, options: [])
                } catch {
                    print("Failed to serialize JSON: \(error)")
                    return
                }
                
                let task = URLSession.shared.dataTask(with: request) { data, response, error in
                    if let error = error {
                        print("Error making POST request: \(error)")
                        return
                    }
                    
                    guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                        print("Server error: \(response.debugDescription)")
                        return
                    }
                    
                    if let data = data {
                        // Move to main thread for calling handler
                        DispatchQueue.main.async {
                            do {
                                // Parse the JSON response
                                if let jsonResponse = try JSONSerialization.jsonObject(with: data, options: []) as? [AnyHashable: AnyObject] {
                                    print("Response JSON: \(jsonResponse)")

                                    // Assign the parsed dictionary to latestReferringParams
                                    self.latestReferringParams = jsonResponse
                                    
                                    if self.handler != nil {
                                        self.handler!(jsonResponse)
                                    }
                                } else {
                                    print("Failed to cast JSON response to [AnyHashable: AnyObject].")
                                }
                            } catch {
                                print("Error parsing response JSON: \(error)")
                            }
                        }
                    }
                }
                
                task.resume()
                
                // Clear the link click ID and/or the Universal Link to prevent a race condition since they've already been used.
                self.linkClickID = nil
                self.universalLink = nil
            }
        }
    }

    /// Get the user agent string for this device.
    private func getUserAgent(completion: @escaping (String?) -> Void) {
        DispatchQueue.main.async {
            let webView = WKWebView()
            webView.evaluateJavaScript("navigator.userAgent") { result, error in
                if let userAgent = result as? String {
                    completion(userAgent)
                } else {
                    print("Error fetching user agent: \(String(describing: error))")
                    completion(nil)
                }
            }
        }
    }
}

@main
class AppDelegate: UIResponder, UIApplicationDelegate {


    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Override point for customization after application launch.
        BranchHandler.shared.handler = { data in
            print(data)
        }
        return true
    }
    
    // MARK: - Linking Lifecycle Methods
    
    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        BranchHandler.shared.continueUserActivity(userActivity)
        return true
    }
    
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        BranchHandler.shared.openURL(url)
        return true
    }
    
    func applicationDidEnterBackground(_ application: UIApplication) {
        BranchHandler.shared.didEnterBackground()
    }

    // MARK: - UISceneSession Lifecycle

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Called when a new scene session is being created.
        // Use this method to select a configuration to create the new scene with.
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        // Called when the user discards a scene session.
        // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
        // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
    }


}

