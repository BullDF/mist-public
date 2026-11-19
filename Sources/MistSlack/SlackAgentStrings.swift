import Foundation

enum SlackAgentStrings {
    static let catchUpChannel = NSLocalizedString("mistSlack.agent.catchUpChannel", value: "Catch me up on %@", comment: "Slack suggested prompt title; %@ is a channel display name including its sigil")
    static let catchUpChannelMessage = NSLocalizedString("mistSlack.agent.catchUpChannelMessage", value: "Catch me up on %@", comment: "Slack suggested prompt message; %@ is a channel link")
    static let summarizeChannel = NSLocalizedString("mistSlack.agent.summarizeChannel", value: "Summarize %@", comment: "Slack suggested prompt title; %@ is a channel display name including its sigil")
    static let summarizeChannelMessage = NSLocalizedString("mistSlack.agent.summarizeChannelMessage", value: "Summarize the recent discussion in %@", comment: "Slack suggested prompt message; %@ is a channel link")
    static let catchUpSlack = NSLocalizedString("mistSlack.agent.catchUpSlack", value: "Catch me up on Slack", comment: "Slack suggested prompt title")
    static let catchUpSlackMessage = NSLocalizedString("mistSlack.agent.catchUpSlackMessage", value: "Catch me up on what I missed in Slack today.", comment: "Slack suggested prompt message")
    static let checkInbox = NSLocalizedString("mistSlack.agent.checkInbox", value: "Check my inbox", comment: "Slack suggested prompt title")
    static let checkInboxMessage = NSLocalizedString("mistSlack.agent.checkInboxMessage", value: "Summarize my unread email.", comment: "Slack suggested prompt message")
    static let planDay = NSLocalizedString("mistSlack.agent.planDay", value: "Plan my day", comment: "Slack suggested prompt title")
    static let planDayMessage = NSLocalizedString("mistSlack.agent.planDayMessage", value: "Look at my Slack and email and tell me what needs my attention today.", comment: "Slack suggested prompt message")
    static let replyWithAnswer = NSLocalizedString("mistSlack.agent.replyWithAnswer", value: "Or reply in this thread with your own answer.", comment: "Slack question card - Free text answer hint")
    static let submit = NSLocalizedString("mistSlack.agent.submit", value: "Submit", comment: "Slack question card - Submit selected answers")
    static let answerEveryQuestion = NSLocalizedString("mistSlack.agent.answerEveryQuestion", value: "Answer every question first.", comment: "Slack question card - Missing answer validation")
    static let noLongerWaiting = NSLocalizedString("mistSlack.agent.noLongerWaiting", value: "This request is no longer waiting.", comment: "Slack card - Request expired or chat closed")
    static let failed = NSLocalizedString("mistSlack.agent.failed", value: "Drifter stopped with an error: %@", comment: "Slack reply when an agent fails; placeholder is the error message")
    static let noWindow = NSLocalizedString("mistSlack.agent.noWindow", value: "Mist has no open window, so Drifter can't start this chat. Open a Mist window and send your message again.", comment: "Slack reply when no normal browser window is open")
    static let modelSet = NSLocalizedString("mistSlack.agent.modelSet", value: "Drifter will use %@ in this thread.", comment: "Slack reply to a message that only names a model; %@ is the model and effort, like Fable 5.1 · medium")
    static let otherEngine = NSLocalizedString("mistSlack.agent.otherEngine", value: "This chat can't switch between Claude and GPT models. Start a new thread to use %@.", comment: "Slack reply when a thread's chat can't switch to the named model; %@ is a model name, like GPT-6.1 Terra")
    static let notTaken = NSLocalizedString("mistSlack.agent.notTaken", value: "Drifter couldn't take this message. Send it again in a moment.", comment: "Slack reply when a message cannot be delivered")
}
