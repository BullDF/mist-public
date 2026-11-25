import Foundation

enum MailStrings {
    static var showNotifications: String { NSLocalizedString("mail.settings.notifications", value: "Show notifications for new mail", comment: "Mail settings - Toggle system notifications for incoming unread mail") }
    static var newMessages: String { NSLocalizedString("mail.notifications.newMessages", value: "%1$d new messages", comment: "Mail notification summary - Number of new unread messages in one account") }
    static var newMessage: String { NSLocalizedString("mail.compose.newMessage", value: "New Message", comment: "Mail compose - Start a new message") }
    static var reply: String { NSLocalizedString("mail.compose.reply", value: "Reply", comment: "Mail compose - Reply to the sender") }
    static var replyAll: String { NSLocalizedString("mail.compose.replyAll", value: "Reply All", comment: "Mail compose - Reply to all recipients") }
    static var forward: String { NSLocalizedString("mail.compose.forward", value: "Forward", comment: "Mail compose - Forward the message") }
    static var quoteIntro: String { NSLocalizedString("mail.compose.quoteIntro", value: "On %1$@, %2$@ wrote:", comment: "Mail compose quote introduction; %1$@ is the date and %2$@ is the sender's name") }
    static var send: String { NSLocalizedString("mail.compose.send", value: "Send", comment: "Mail compose - Send the composed message") }
    static var attachFiles: String { NSLocalizedString("mail.compose.attachFiles", value: "Attach Files…", comment: "Mail compose - Choose files to attach") }
    static var discardDraft: String { NSLocalizedString("mail.compose.discardDraft", value: "Discard Draft", comment: "Mail compose - Delete the draft locally and on the server") }
    static var closeCompose: String { NSLocalizedString("mail.compose.closeCompose", value: "Close", comment: "Mail compose - Close compose and keep the edited draft") }
    static var discardConfirmation: String { NSLocalizedString("mail.compose.discardConfirmation", value: "Discard this draft?", comment: "Mail compose - Confirm deleting a draft with content") }
    static var discardMessage: String { NSLocalizedString("mail.compose.discardMessage", value: "The draft will be deleted from this Mac and the mail server.", comment: "Mail compose - Explain draft deletion") }
    static var fromField: String { NSLocalizedString("mail.compose.fromField", value: "From", comment: "Mail compose - Sender account field") }
    static var toField: String { NSLocalizedString("mail.compose.toField", value: "To", comment: "Mail compose - Recipient field") }
    static var ccField: String { NSLocalizedString("mail.compose.ccField", value: "Cc", comment: "Mail compose - Carbon copy recipient field") }
    static var bccField: String { NSLocalizedString("mail.compose.bccField", value: "Bcc", comment: "Mail compose - Blind carbon copy recipient field") }
    static var ccBcc: String { NSLocalizedString("mail.compose.ccBcc", value: "Cc/Bcc", comment: "Mail compose - Reveal additional recipient fields") }
    static var suggestions: String { NSLocalizedString("mail.compose.recipientSuggestions", value: "Suggested recipients", comment: "Mail compose - Accessibility label for the list of suggested recipients under a recipient field") }
    static var subjectField: String { NSLocalizedString("mail.compose.subjectField", value: "Subject", comment: "Mail compose - Message subject field") }
    static var messageBody: String { NSLocalizedString("mail.compose.messageBody", value: "Message Body", comment: "Mail compose - Rich text editor accessibility label") }
    static var bold: String { NSLocalizedString("mail.compose.bold", value: "Bold", comment: "Mail compose - Bold formatting") }
    static var italic: String { NSLocalizedString("mail.compose.italic", value: "Italic", comment: "Mail compose - Italic formatting") }
    static var underline: String { NSLocalizedString("mail.compose.underline", value: "Underline", comment: "Mail compose - Underline formatting") }
    static var strikethrough: String { NSLocalizedString("mail.compose.strikethrough", value: "Strikethrough", comment: "Mail compose - Strikethrough formatting") }
    static var textSize: String { NSLocalizedString("mail.compose.textSize", value: "Text Size", comment: "Mail compose - Text size picker") }
    static var small: String { NSLocalizedString("mail.compose.small", value: "Small", comment: "Mail compose - Small text size") }
    static var normal: String { NSLocalizedString("mail.compose.normal", value: "Normal", comment: "Mail compose - Normal text size") }
    static var large: String { NSLocalizedString("mail.compose.large", value: "Large", comment: "Mail compose - Large text size") }
    static var huge: String { NSLocalizedString("mail.compose.huge", value: "Huge", comment: "Mail compose - Largest text size") }
    static var signature: String { NSLocalizedString("mail.account.signature", value: "Signature", comment: "Mail - Account signature section and editor label") }
    static var signatureTooLong: String { NSLocalizedString("mail.account.signatureTooLong", value: "This signature is too long.", comment: "Mail - Account signature exceeded its UTF-8 size limit") }
    static var font: String { NSLocalizedString("mail.compose.font", value: "Font", comment: "Mail - Formatting toolbar font picker") }
    static var defaultFont: String { NSLocalizedString("mail.compose.defaultFont", value: "Default", comment: "Mail - Default message body font") }
    static var formattingOther: String { NSLocalizedString("mail.compose.otherFormatting", value: "Other…", comment: "Mail - Open the system font or color panel") }
    static var customColor: String { NSLocalizedString("mail.compose.customColor", value: "Custom", comment: "Mail - Selected text color outside the palette") }
    static var textColor: String { NSLocalizedString("mail.compose.textColor", value: "Text Color", comment: "Mail compose - Text color picker") }
    static var defaultColor: String { NSLocalizedString("mail.compose.defaultColor", value: "Default", comment: "Mail compose - Default black text color") }
    static var gray: String { NSLocalizedString("mail.compose.gray", value: "Gray", comment: "Mail compose - Gray text color") }
    static var red: String { NSLocalizedString("mail.compose.red", value: "Red", comment: "Mail compose - Red text color") }
    static var orange: String { NSLocalizedString("mail.compose.orange", value: "Orange", comment: "Mail compose - Orange text color") }
    static var green: String { NSLocalizedString("mail.compose.green", value: "Green", comment: "Mail compose - Green text color") }
    static var blue: String { NSLocalizedString("mail.compose.blue", value: "Blue", comment: "Mail compose - Blue text color") }
    static var purple: String { NSLocalizedString("mail.compose.purple", value: "Purple", comment: "Mail compose - Purple text color") }
    static var bulletedList: String { NSLocalizedString("mail.compose.bulletedList", value: "Bulleted List", comment: "Mail compose - Toggle a bulleted list") }
    static var numberedList: String { NSLocalizedString("mail.compose.numberedList", value: "Numbered List", comment: "Mail compose - Toggle a numbered list") }
    static var decreaseIndent: String { NSLocalizedString("mail.compose.decreaseIndent", value: "Decrease Indent", comment: "Mail compose - Decrease paragraph indentation") }
    static var increaseIndent: String { NSLocalizedString("mail.compose.increaseIndent", value: "Increase Indent", comment: "Mail compose - Increase paragraph indentation") }
    static var link: String { NSLocalizedString("mail.compose.link", value: "Link…", comment: "Mail compose - Edit a link in a sheet") }
    static var linkURL: String { NSLocalizedString("mail.compose.linkURL", value: "URL", comment: "Mail compose - Link destination field") }
    static var ok: String { NSLocalizedString("mail.compose.ok", value: "OK", comment: "Mail compose - Apply the link") }
    static var removeLink: String { NSLocalizedString("mail.compose.removeLink", value: "Remove Link", comment: "Mail compose - Remove the selected link") }
    static var clearFormatting: String { NSLocalizedString("mail.compose.clearFormatting", value: "Clear Formatting", comment: "Mail compose - Remove text formatting") }
    static var noRecipients: String { NSLocalizedString("mail.compose.noRecipients", value: "Add at least one recipient.", comment: "Mail compose - Sending requires a recipient") }
    static var invalidRecipient: String { NSLocalizedString("mail.compose.invalidRecipient", value: "Check the recipient email addresses.", comment: "Mail compose - Sending requires valid addresses in every recipient field") }
    static var accounts: String { NSLocalizedString("mail.settings.accounts", value: "Accounts", comment: "Mail settings - Accounts section title") }
    static var add: String { NSLocalizedString("mail.settings.add", value: "Add Account…", comment: "Mail settings - Add account button") }
    static var edit: String { NSLocalizedString("mail.settings.edit", value: "Edit…", comment: "Mail settings - Edit account button") }
    static var reconnect: String { NSLocalizedString("mail.settings.reconnect", value: "Reconnect", comment: "Mail settings - Button on an account that isn't connected: connect it again now") }
    static var remove: String { NSLocalizedString("mail.settings.remove", value: "Remove", comment: "Mail settings - Remove account button") }
    static var removeTitle: String { NSLocalizedString("mail.settings.removeTitle", value: "Remove %@?", comment: "Mail settings confirmation - %@ is account name") }
    static var removeMessage: String { NSLocalizedString("mail.settings.removeMessage", value: "Mail downloaded to Phi is deleted. Nothing is deleted from the server.", comment: "Mail settings confirmation - Removing local account data only") }
    static var removeMessageSynced: String { NSLocalizedString("mail.settings.removeMessageSynced", value: "Mail downloaded to Phi is deleted, and the account is removed from your other Macs. Nothing is deleted from the server.", comment: "Mail account removal alert - Message when Mist sync is on") }
    static var cancel: String { NSLocalizedString("mail.settings.cancel", value: "Cancel", comment: "Mail account sheet or removal confirmation - Cancel button") }
    static var signIn: String { NSLocalizedString("mail.settings.signIn", value: "Sign In", comment: "Mail account sheet - Verify credentials and save account") }
    static var editAccount: String { NSLocalizedString("mail.settings.editTitle", value: "Edit Account", comment: "Mail account sheet - Edit title") }
    static var addAccountTitle: String { NSLocalizedString("mail.settings.addTitle", value: "Add Account", comment: "Mail account sheet - Add title") }
    static var preset: String { NSLocalizedString("mail.settings.preset", value: "Account type", comment: "Mail account sheet - Server preset picker label") }
    static var other: String { NSLocalizedString("mail.settings.other", value: "Other", comment: "Mail account sheet - Custom mail provider preset") }
    static var accountName: String { NSLocalizedString("mail.settings.accountName", value: "Account name", comment: "Mail account sheet - Display name field label") }
    static var yourName: String { NSLocalizedString("mail.settings.yourName", value: "Your name", comment: "Mail account sheet - Sender display name field label") }
    static var email: String { NSLocalizedString("mail.settings.email", value: "Email", comment: "Mail account sheet - Email address field label") }
    static var username: String { NSLocalizedString("mail.settings.username", value: "Username", comment: "Mail account sheet - Authentication username field label") }
    static var password: String { NSLocalizedString("mail.settings.password", value: "Password", comment: "Mail account sheet - Secure password field label") }
    static var unchangedPassword: String { NSLocalizedString("mail.settings.unchangedPassword", value: "Leave empty to keep the current password", comment: "Mail account sheet - Edit password placeholder") }
    static var servers: String { NSLocalizedString("mail.settings.servers", value: "Server settings", comment: "Mail account sheet - Advanced server settings disclosure") }
    static var imapHost: String { NSLocalizedString("mail.settings.imapHost", value: "IMAP host", comment: "Mail account sheet - Incoming server hostname") }
    static var smtpHost: String { NSLocalizedString("mail.settings.smtpHost", value: "SMTP host", comment: "Mail account sheet - Outgoing server hostname") }
    static var port: String { NSLocalizedString("mail.settings.port", value: "Port", comment: "Mail account sheet - Server port number") }
    static var security: String { NSLocalizedString("mail.settings.security", value: "Security", comment: "Mail account sheet - Server encryption picker") }
    static var noSecurity: String { NSLocalizedString("mail.settings.noSecurity", value: "None (localhost only)", comment: "Mail account sheet - Unencrypted local server option") }
    static var gmailHint: String { NSLocalizedString("mail.settings.gmailHint", value: "Use an app password, not your Google password", comment: "Mail account sheet - Link to Google's app password settings") }
    static var invalidConfiguration: String { NSLocalizedString("mail.errors.invalidConfiguration", value: "Check your email, username, and server settings.", comment: "Mail account form - Invalid configuration error") }
    static var authenticationFailed: String { NSLocalizedString("mail.errors.authentication", value: "Couldn't sign in. Check your username and password.", comment: "Mail account form - Credentials rejected") }
    static var cannotConnect: String { NSLocalizedString("mail.errors.connect", value: "Couldn't connect to the mail server.", comment: "Mail account form - Network connection failed") }
    static var tlsFailure: String { NSLocalizedString("mail.errors.tls", value: "Couldn't establish a secure connection.", comment: "Mail account form - TLS negotiation failed") }
    static var timeout: String { NSLocalizedString("mail.errors.timeout", value: "The mail server didn't respond in time.", comment: "Mail account form - Server timeout") }
    static var offline: String { NSLocalizedString("mail.errors.offline", value: "You're offline. Connect to the internet and try again.", comment: "Mail account form - No network") }
    static var serverRejected: String { NSLocalizedString("mail.errors.rejected", value: "The mail server rejected the request.", comment: "Mail account form - Server refused the operation") }
    static var unsupported: String { NSLocalizedString("mail.errors.unsupported", value: "This mail server doesn't support the required operation.", comment: "Mail account form - Unsupported operation") }
    static var missingItem: String { NSLocalizedString("mail.errors.missingItem", value: "This mail account or message is no longer available.", comment: "Mail account form - Missing account or message") }
    static var missingCredentials: String { NSLocalizedString("mail.errors.missingCredentials", value: "Enter your password to sign in again.", comment: "Mail account form - Missing stored password") }
    static var storageFailure: String { NSLocalizedString("mail.errors.storage", value: "Couldn't save mail data. Please try again.", comment: "Mail account form - Local database or file error") }
    static var openLink: String { NSLocalizedString("mail.reader.openLink", value: "Open Link", comment: "Mail body context menu - Open link in a Mist tab") }
    static var retry: String { NSLocalizedString("mail.reader.retry", value: "Retry", comment: "Mail reader - Retry loading message") }
    static var openAttachment: String { NSLocalizedString("mail.attachment.open", value: "Open", comment: "Mail attachment - Open in default app") }
    static var saveAttachment: String { NSLocalizedString("mail.attachment.save", value: "Save As…", comment: "Mail attachment - Save a copy") }
    static var attachment: String { NSLocalizedString("mail.attachment.unnamed", value: "Attachment", comment: "Mail attachment - Missing filename") }
    static var attachmentFailed: String { NSLocalizedString("mail.errors.attachment", value: "Couldn't open the attachment", comment: "Mail reader - Download or save attachment failed") }
    static var found: String { NSLocalizedString("mail.find.found", value: "Found", comment: "Mail reader find bar - A match was found") }
    static var notFound: String { NSLocalizedString("mail.find.notFound", value: "Not found", comment: "Mail reader find bar - No match") }
    static var mailboxes: String { NSLocalizedString("mail.mailboxes.title", value: "Mailboxes", comment: "Mail sidebar - Accessibility label") }
    static var messages: String { NSLocalizedString("mail.messages.title", value: "Messages", comment: "Mail list - Accessibility label") }
    static var loading: String { NSLocalizedString("mail.loading", value: "Loading…", comment: "Mail page - Loading progress") }
    static var inbox: String { NSLocalizedString("mail.mailboxes.inbox", value: "Inbox", comment: "Mail sidebar - An account's inbox") }
    static var unifiedInbox: String { NSLocalizedString("mail.mailboxes.unifiedInbox", value: "All Inboxes", comment: "Mail sidebar - Inbox across all accounts") }
    static var unifiedDrafts: String { NSLocalizedString("mail.mailboxes.unifiedDrafts", value: "All Drafts", comment: "Mail sidebar - Drafts across all accounts") }
    static var unifiedSent: String { NSLocalizedString("mail.mailboxes.unifiedSent", value: "All Sent", comment: "Mail sidebar - Sent mail across all accounts") }
    static var unifiedTrash: String { NSLocalizedString("mail.mailboxes.unifiedTrash", value: "All Trash", comment: "Mail sidebar - Trash across all accounts") }
    static var unifiedSpam: String { NSLocalizedString("mail.mailboxes.unifiedSpam", value: "All Junk", comment: "Mail sidebar - Spam across all accounts") }
    static var markAllRead: String { NSLocalizedString("mail.actions.markAllRead", value: "Mark All as Read", comment: "Mail toolbar - Mark every message in the selected mailboxes read") }
    static var undo: String { NSLocalizedString("mail.actions.undo", value: "Undo", comment: "Mail banner - Name of the action that reverses a message change") }
    static var redo: String { NSLocalizedString("mail.actions.redo", value: "Redo", comment: "Mail banner - Name of the action that reapplies an undone message change") }
    static var searchMail: String { NSLocalizedString("mail.search.placeholder", value: "Search Mail", comment: "Mail list - Search field placeholder and accessibility label") }
    static var searchOnServer: String { NSLocalizedString("mail.search.server", value: "Search on Server", comment: "Mail search - Search selected mailboxes on the server") }
    static var noResults: String { NSLocalizedString("mail.search.noResults", value: "No results", comment: "Mail list - Empty search result") }
    static var emptyMailbox: String { NSLocalizedString("mail.messages.empty", value: "No messages", comment: "Mail list - Empty mailbox") }
    static var noSubject: String { NSLocalizedString("mail.messages.noSubject", value: "(No Subject)", comment: "Mail message - Missing subject") }
    static var to: String { NSLocalizedString("mail.message.to", value: "To: %@", comment: "Mail message - Recipient names, %@ is the address list") }
    static var cc: String { NSLocalizedString("mail.message.cc", value: "Cc: %@", comment: "Mail message - Carbon copy recipients, %@ is the address list") }
    static var yesterday: String { NSLocalizedString("mail.messages.yesterday", value: "Yesterday", comment: "Mail list - Date for yesterday") }
    static var refresh: String { NSLocalizedString("mail.toolbar.refresh", value: "Refresh Mailbox", comment: "Mail toolbar - Refresh selected mailbox") }
    static var toggleSidebar: String { NSLocalizedString("mail.toolbar.toggleMailboxes", value: "Show or Hide Mailboxes", comment: "Mail toolbar - Toggle mailbox pane") }
    static var markRead: String { NSLocalizedString("mail.actions.markRead", value: "Mark as Read", comment: "Mail action - Mark message read") }
    static var markUnread: String { NSLocalizedString("mail.actions.markUnread", value: "Mark as Unread", comment: "Mail action - Mark message unread") }
    static var flag: String { NSLocalizedString("mail.actions.flag", value: "Flag", comment: "Mail action - Flag message") }
    static var unflag: String { NSLocalizedString("mail.actions.unflag", value: "Unflag", comment: "Mail action - Remove message flag") }
    static var archive: String { NSLocalizedString("mail.actions.archive", value: "Archive", comment: "Mail action - Archive message") }
    static var delete: String { NSLocalizedString("mail.actions.delete", value: "Delete", comment: "Mail action - Move message to Trash") }
    static var move: String { NSLocalizedString("mail.actions.move", value: "Move to", comment: "Mail menu - Destination mailbox submenu") }
    static var settings: String { NSLocalizedString("mail.accounts.settings", value: "Mail Settings…", comment: "Mail error banner - Open Mail settings") }
    static var signInFailed: String { NSLocalizedString("mail.accounts.signInFailed", value: "Couldn't sign in to %@", comment: "Mail error banner - %@ is account name") }
    static var loadFailed: String { NSLocalizedString("mail.errors.load", value: "Couldn't load mail", comment: "Mail page - Cache or database read failed") }
    static var refreshFailed: String { NSLocalizedString("mail.errors.refresh", value: "Couldn't refresh mail", comment: "Mail page - Mailbox sync failed") }
    static var actionFailed: String { NSLocalizedString("mail.errors.action", value: "Couldn't complete the mail action", comment: "Mail banner - Failed action from another mail page") }
    static var couldNotAction: String { NSLocalizedString("mail.errors.namedAction", value: "Couldn't complete: %@", comment: "Mail banner - %@ is the localized failed action name") }
    static var connected: String { NSLocalizedString("mail.status.connected", value: "Connected", comment: "Mail account status") }
    static var connecting: String { NSLocalizedString("mail.status.connecting", value: "Connecting…", comment: "Mail account status") }
    static var syncing: String { NSLocalizedString("mail.status.syncing", value: "Syncing…", comment: "Mail account status") }
    static var retrying: String { NSLocalizedString("mail.status.retrying", value: "Retrying…", comment: "Mail account status") }
    static var disconnected: String { NSLocalizedString("mail.status.disconnected", value: "Offline", comment: "Mail account status") }
    static var authFailed: String { NSLocalizedString("mail.status.authFailed", value: "Sign-in failed", comment: "Mail account status") }
    static var addAccount: String { NSLocalizedString("mail.accounts.add", value: "Add a mail account", comment: "Mail page - Empty state button opening Mail settings") }
    static var noAccountsTitle: String { NSLocalizedString("mail.accounts.emptyTitle", value: "No mail accounts", comment: "Mail page - Empty state title when no account is set up") }
    static var noAccountsMessage: String { NSLocalizedString("mail.accounts.emptyMessage", value: "Add an account to read, search and send mail in Phi.", comment: "Mail page - Empty state explanation under the title, above the Add button") }
    static var noSelection: String { NSLocalizedString("mail.reader.noSelection", value: "Select a message to read", comment: "Mail reading pane - No message selected") }
}
