import Foundation

enum MistSlackStrings {
    static let drifterInSlack = NSLocalizedString("mistSlack.drifterInSlack", value: "Drifter in Slack", comment: "Slack settings - Section for Drifter's Socket Mode connection")
    static let answerInSlack = NSLocalizedString("mistSlack.answerInSlack", value: "Answer in Slack", comment: "Slack settings - Switch enabling replies from this build of the browser")
    static let answerOff = NSLocalizedString("mistSlack.answerOff", value: "Drifter doesn't answer in Slack from this Phi.", comment: "Slack settings - Connection is disabled in this browser")
    static let answerMissingTokens = NSLocalizedString("mistSlack.answerMissingTokens", value: "Add the bot and app tokens to answer in Slack.", comment: "Slack settings - Connection needs all three tokens")
    static let answerConnecting = NSLocalizedString("mistSlack.answerConnecting", value: "Connecting to Slack…", comment: "Slack settings - Socket Mode connection in progress")
    static let answerConnected = NSLocalizedString("mistSlack.answerConnected", value: "Connected. Drifter answers your Slack threads from this Phi.", comment: "Slack settings - This browser is the only Socket Mode connection")
    static let answerShared = NSLocalizedString("mistSlack.answerShared", value: "Connected, but another app is also connected to Drifter. Slack splits events between them, so turn off Answer in Slack in the other Phi.", comment: "Slack settings - Multiple Socket Mode connections share events; Answer in Slack is the switch label")
    static let answerFailed = NSLocalizedString("mistSlack.answerFailed", value: "Slack refused the connection: %@", comment: "Slack settings - Connection failure; placeholder is the Slack error code")
    static let title = NSLocalizedString("mistSlack.title", value: "Slack", comment: "Slack settings - Settings pane title")
    static let workspace = NSLocalizedString("mistSlack.workspace", value: "Workspace", comment: "Slack settings - Connected workspace section and name label")
    static let signedInAs = NSLocalizedString("mistSlack.signedInAs", value: "Signed in as", comment: "Slack settings - Connected user label")
    static let bot = NSLocalizedString("mistSlack.bot", value: "Bot", comment: "Slack settings - Connected bot name label")
    static let tokens = NSLocalizedString("mistSlack.tokens", value: "Tokens", comment: "Slack settings - Token fields section title")
    static let userToken = NSLocalizedString("mistSlack.userToken", value: "User token", comment: "Slack settings - User token field label")
    static let botToken = NSLocalizedString("mistSlack.botToken", value: "Bot token", comment: "Slack settings - Bot token field label")
    static let appToken = NSLocalizedString("mistSlack.appToken", value: "App token", comment: "Slack settings - App token field label")
    static let saved = NSLocalizedString("mistSlack.saved", value: "Saved", comment: "Slack settings - Placeholder for a token already stored in the keychain")
    static let save = NSLocalizedString("mistSlack.save", value: "Save", comment: "Slack settings - Save and validate tokens button")
    static let hint = NSLocalizedString("mistSlack.hint", value: "Drifter's Slack tools use the user token and act as you. The bot and app tokens are for Drifter in Slack.", comment: "Slack settings - Explain the roles of the three tokens")
    static let removeTokens = NSLocalizedString("mistSlack.removeTokens", value: "Remove tokens", comment: "Slack settings - Button to remove saved tokens")
    static let removeTitle = NSLocalizedString("mistSlack.removeTitle", value: "Remove the Slack tokens?", comment: "Slack settings - Token removal confirmation title")
    static let removeMessage = NSLocalizedString("mistSlack.removeMessage", value: "Drifter chats lose their Slack tools until you add the tokens again.", comment: "Slack settings - Token removal confirmation explanation")
    static let remove = NSLocalizedString("mistSlack.remove", value: "Remove", comment: "Slack settings - Confirm removal button")
    static let cancel = NSLocalizedString("mistSlack.cancel", value: "Cancel", comment: "Slack settings - Cancel token removal button")
    static let errorTokenFormat = NSLocalizedString("mistSlack.errorTokenFormat", value: "Check the tokens: the user token starts with xoxp-, the bot token with xoxb- and the app token with xapp-.", comment: "Slack settings - Malformed token error; preserve token prefixes")
    static let errorUserToken = NSLocalizedString("mistSlack.errorUserToken", value: "Add the user token.", comment: "Slack settings - Missing user token error")
    static let errorAuth = NSLocalizedString("mistSlack.errorAuth", value: "Slack rejected the token.", comment: "Slack settings - Slack authentication error")
    static let errorNetwork = NSLocalizedString("mistSlack.errorNetwork", value: "Phi can't reach Slack.", comment: "Slack settings - Network connection error")
    static let errorKeychain = NSLocalizedString("mistSlack.errorKeychain", value: "The tokens couldn't be saved in the keychain.", comment: "Slack settings - Keychain storage error")
    static let errorOther = NSLocalizedString("mistSlack.errorOther", value: "Slack returned an error: %@", comment: "Slack settings - Other Slack error; placeholder is the error code")

    static func message(_ error: Error) -> String {
        if (error as NSError).domain == NSOSStatusErrorDomain { return errorKeychain }
        let code = (error as? SlackAPIError)?.code ?? String((error as NSError).code)
        switch code {
        case "invalid_token_format": return errorTokenFormat
        case "missing_user_token": return errorUserToken
        case "invalid_auth", "not_authed", "token_revoked", "token_expired", "account_inactive": return errorAuth
        case "network": return errorNetwork
        default: return String(format: errorOther, code)
        }
    }
}
