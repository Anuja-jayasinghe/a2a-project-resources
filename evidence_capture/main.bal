import ballerina/a2a;
import ballerina/http;
import ballerina/io;

isolated function unusedHttpVersionPinAnchor() returns http:ClientConfiguration {
    return {};
}

public function main() returns error? {
    string url = "http://localhost:10000";
    a2a:AgentCard card = check a2a:resolveAgentCard(url);

    a2a:Client c = check new (url, {timeout: 30}, agentCard = card);

    io:println("=== Push notification config CRUD (create/get/list) ===");
    a2a:Message msg = {
        messageId: "evidence-push-1",
        role: a2a:ROLE_USER,
        parts: [{text: "What is the exchange rate between USD and CAD?"}]
    };
    a2a:Task|a2a:Message sendResult = check c->sendMessage(msg);
    a2a:Task created = <a2a:Task>sendResult;
    io:println("Task created: ", created.id, " status=", created.status.state);

    a2a:TaskPushNotificationConfig config = {
        url: "https://example.com/webhook",
        taskId: created.id
    };
    a2a:TaskPushNotificationConfig createdConfig = check c->createTaskPushNotificationConfig(config);
    string configId = <string>createdConfig?.id;
    io:println("CREATE -> ", createdConfig.toJsonString());

    a2a:TaskPushNotificationConfig fetchedConfig = check c->getTaskPushNotificationConfig(created.id, configId);
    io:println("GET    -> ", fetchedConfig.toJsonString());

    a2a:ListTaskPushNotificationConfigsResult listedConfigs = check c->listTaskPushNotificationConfigs(created.id);
    io:println("LIST   -> ", listedConfigs.toJsonString());

    io:println();
    io:println("=== Genuine in-flight cancelTask (racing a real, still-running task) ===");
    a2a:Message longMsg = {
        messageId: "evidence-cancel-1",
        role: a2a:ROLE_USER,
        parts: [{text: "What is the exchange rate between USD and JPY, and also GBP and AUD, and also EUR and CHF?"}]
    };
    a2a:Task|a2a:Message longResult = check c->sendMessage(longMsg);
    a2a:Task longTask = <a2a:Task>longResult;
    io:println("Task submitted: ", longTask.id, " (immediately racing a cancel against it)");

    a2a:Task cancelResult = check c->cancelTask(longTask.id);
    io:println("cancelTask response -> status=", cancelResult.status.state);

    a2a:Task confirmed = check c->getTask(longTask.id);
    io:println("Follow-up getTask (durability check) -> status=", confirmed.status.state);
}
