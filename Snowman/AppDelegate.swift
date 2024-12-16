//
//  AppDelegate.swift
//  Snowman
//
//  Created by Nick Rogers on 3/6/23.
//

import UIKit
import WebKit

class BranchHandler {
    /// The handler where deep link data is returned after successful Branch initialization.
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
        
        // Schedule a delayed initiation of the v1/open request to allow app launch to complete.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.initiateBranchOpenRequest()
        }
    }
    
    // MARK: Lifecycle methods
    
    /// Handle data from the AppDelegate's continueUserActivity() lifecycle method.
    /// This is used to handle an incoming web URL that represents an Associated Domain for Universal Linking.
    func continueUserActivity(_ userActivity: NSUserActivity) {
        // Extract the web URL from the NSUserActivity object
        if let webURL = userActivity.webpageURL {
            self.universalLink = webURL.absoluteString
            
            // We have a web URL, so initiate the v1/open request after saving that web URL
            initiateBranchOpenRequest()
        }
    }
    
    /// Handle data from the AppDelegate's openURL() lifecycle method.
    /// This is used to handle incoming data from a URI scheme that triggered the app open.
    func openURL(_ url: URL) {
        // Parse the URL's query items
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryItems = components.queryItems {
            
            // Find the "link_click_id" query parameter
            if let linkClickID = queryItems.first(where: { $0.name == "link_click_id" })?.value {
                print("Extracted link_click_id: \(linkClickID)")
                
                // Save the link click ID for future use.
                self.linkClickID = linkClickID
                
                // Initiate the v1/open request since the app opened from a URI scheme
                initiateBranchOpenRequest()
            } else {
                print("link_click_id not found in the URL.")
            }
        } else {
            print("Invalid URL or no query items present.")
        }
    }
    
    /// Handle the app entering the background.
    func didEnterBackground() {
        // Reset the limiter for opens so that if the app is launched from a link, we'll make a new call to retrieve deep link data
        openCallTriggered = false
    }
    
    // MARK: Branch API calls
    
    /// Make a request to Branch's v1/open endpoint if it's appropriate to do so.
    private func initiateBranchOpenRequest() {
        // If we've already hit the open endpoint, don't do it again.
        if openCallTriggered {
            return
        } else {
            openCallTriggered = true
        }
        
        // Retrieve the User Agent string asynchronously
        self.getUserAgent { userAgentString in
            DispatchQueue.global(qos: .userInteractive).async {
                // Fetch the app version from the app's Info.plist
                var version: String?
                if let infoDictionary = Bundle.main.infoDictionary {
                    version = infoDictionary["CFBundleShortVersionString"] as? String
                }
                
                // Retrieve the operating system version
                let osVersion = ProcessInfo.processInfo.operatingSystemVersion
                
                // Build the request body for the v1/open API call
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
                
                // Include the hardware ID (Identifier for Vendor)
                if let idfv = UIDevice.current.identifierForVendor {
                    requestBody["hardware_id"] = idfv.uuidString
                    requestBody["hardware_id_type"] = "vendor_id"
                    requestBody["ios_vendor_id"] = idfv.uuidString
                }
                
                // Include the Universal Link or Link Click ID
                if let universalLink = self.universalLink {
                    requestBody["universal_link_url"] = universalLink
                } else if let linkClickID = self.linkClickID {
                    requestBody["link_identifier"] = linkClickID
                }
                
                // Prepare the POST request to the v1/open endpoint
                guard let url = URL(string: "https://api2.branch.io/v1/open") else {
                    print("Invalid URL")
                    return
                }
                
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                
                do {
                    // Serialize the request body into JSON format
                    request.httpBody = try JSONSerialization.data(withJSONObject: requestBody, options: [])
                } catch {
                    print("Failed to serialize JSON: \(error)")
                    return
                }
                
                // Perform the API call using URLSession
                let task = URLSession.shared.dataTask(with: request) { data, response, error in
                    if let error = error {
                        print("Error making POST request: \(error)")
                        return
                    }
                    
                    // Check for a successful HTTP status code
                    guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                        print("Server error: \(response.debugDescription)")
                        return
                    }
                    
                    if let data = data {
                        // Parse the JSON response and call the handler
                        DispatchQueue.main.async {
                            do {
                                if let jsonResponse = try JSONSerialization.jsonObject(with: data, options: []) as? [AnyHashable: AnyObject] {
                                    print("Response JSON: \(jsonResponse)")
                                    self.latestReferringParams = jsonResponse
                                    
                                    // Call the handler with the parsed data
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
                
                // Clear the link click ID and Universal Link to avoid race conditions
                self.linkClickID = nil
                self.universalLink = nil
            }
        }
    }

    /// Get the user agent string for this device using a WKWebView.
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

    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Override point for customization after application launch.
        BranchHandler.shared.handler = { data in
            print(data)
        }
        
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = SMHomeViewController()
        window?.makeKeyAndVisible()
        
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

//    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
//        // Called when a new scene session is being created.
//        // Use this method to select a configuration to create the new scene with.
//        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
//    }
//
//    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
//        // Called when the user discards a scene session.
//        // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
//        // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
//    }


}

