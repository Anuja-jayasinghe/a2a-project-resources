# A2A Technical Design — Superseded Listener/Service Draft

This archive contains an earlier, unversioned draft of the A2A Technical Design, superseded by the Phase 1 Client Technical Design. Kept here for historical reference only — do not implement from this section. See `a2a/CLAUDE.md` for implementation guidance.

---

> ⚠️ **SUPERSEDED — do not implement from this section.**
>
> Everything from here down to "Task Delegation Lifecycle" below is an
> earlier, unversioned draft of this design, superseded by the
> "Phase 1: Client Technical Design" section of `docs/A2A_Technical_Design.md`
> (this content used to live in that same file, directly above this
> section, before being moved into this archive file — the caveat below
> still refers to it as "above" in that original sense; it is not above
> within *this* file). It disagrees with the Phase 1 draft in at least
> three confirmed places, independently verified against the live A2A
> spec (https://a2a-protocol.org/latest/specification/) — the Phase 1
> draft is correct in all three:
>
> - **`AgentInterface.tenant`** — this draft's `AgentInterface` omits the
>   `tenant` field entirely; Phase 1 §3.2 includes it, and the client's
>   tenant-routing design (§9.4) depends on it.
> - **`AgentProvider.url`** — this draft makes it optional
>   (`string? url?`); Phase 1 §3.2 makes it required (`string url`).
> - **`TaskArtifactUpdateEvent.index`** — this draft still carries an
>   `index` field; Phase 1 §3.5 contains an explicit correction note
>   removing it, since specification §4.2.2 defines no such field.
>
> This section also sketches Phase 2 (Listener/service) material that is
> out of scope for Phase 1 regardless of the above. Kept here for
> historical reference only — always implement from the Phase 1 section
> of `docs/A2A_Technical_Design.md`, per `a2a/CLAUDE.md`.

---

# A2A Library for Ballerina — Technical Design1

**A2A Library for Ballerina — Technical Design**1\. Scope & recap

The design outline proposed an A2A library for Ballerina with three public surfaces: a2a:Client (outbound calls to other agents), a2a:Listener (hosting an A2A-reachable agent).This document picks up from that conclusion and works through how each piece is actually built.

* In scope: module layout, the core data model, client design, listener/service design and the task lifecycle, the task store, transport/streaming mechanics, and security configuration.

* Out of scope (carried over from the outline's open questions): automatic name-based task dispatch, a hardened mTLS implementation, a persistent (non-in-memory) task store implementation, and Choreo agent-directory integration. Each is restated under Open Questions (11) with what would need to happen to unblock it.

# **2\. Module layout**

Proposed package: ballerina/a2a, mirroring the file-per-concern convention already used in ballerina/mcp so the two agent-protocol libraries read consistently.

```
ballerina/a2a/
  types.bal       — AgentCard, AgentSkill, Message, Part,
                    Task, TaskStatus, Artifact,
                    TaskStatusUpdateEvent, TaskArtifactUpdateEvent
  client.bal      — a2a:Client class
  listener.bal    — a2a:Listener class + service-object contract
  task_store.bal  — TaskStore interface + InMemoryTaskStore default
  errors.bal      — a2a:Error subtypes, mapped to JSON-RPC error codes
  modules/
  	transport/      — internal JSON-RPC ↔ SSE plumbing (not exported)
		  jsonrpc.bal
		  sse.bal
```

*What this shows: each file owns one concern, and TaskStore is the only piece adopters are meant to extend themselves.*

* **Task, Client,** and **Listener** are marked **public** in the package's default module that's the supported surface. **Wire-format** and **transport** internals live in the transport submodule and aren't part of the supported API

* TaskStore is the one extension point exposed for production use — everything else in the module is consumed as-is.

# **3\. Core data model**

These mirror the A2A spec's JSON objects field-for-field, expressed as Ballerina records:

```
public type AgentCard record {
    string name;
    string description;
    string version;
    string url;
    AgentProvider? provider?;
    string? documentationUrl?;
    string? iconUrl?;
    AgentCapabilities capabilities;
    AgentInterface[] supportedInterfaces = [];
    map<json> securitySchemes = {};
    json[] security = [];
    string[] defaultInputModes = ["text"];
    string[] defaultOutputModes = ["text"];
    AgentSkill[] skills;
    json[] signatures = [];
    json...;
};
 
public type AgentSkill record {
    string id;
    string name;
    string description;
    string[] tags = [];
    string[] inputModes = [];
    string[] outputModes = [];
    string[] examples = [];
    json...;
};

public type AgentExtension record {
    string uri;
    string? description?;
    boolean required = false;
    json...;
};

public type AgentCapabilities record {
    boolean streaming = false;
    boolean pushNotifications = false;
    boolean stateTransitionHistory = false;
    boolean extendedAgentCard = false;
    AgentExtension[] extensions = [];
    json...;
};

public type AgentProvider record {
    string organization;
    string? url?;
    string? contactEmail?;
    json...;
};

public type AgentInterface record {
    string url;
    string protocolBinding;
    string? protocolVersion?;
    json...;
};

```

*AgentCard is the document other agents fetch to learn what this agent can do; each AgentSkill in it is one capability they're allowed to invoke.*

```
public enum Role {
    ROLE_UNSPECIFIED,
    ROLE_USER,
    ROLE_AGENT
};

public type Message record {
    string messageId;
    Role role;
    Part[] parts;
    string? contextId?;
    string? taskId?;
    string[] referenceTaskIds = [];
    string[] extensions = [];
    map<json>? metadata?;
    json...;
};

public type Part record {
    string? text?;
    string? url?;
    byte[]? raw?;
    string? filename?;
    string? mediaType?;
    json? data?;
    map<json>? metadata?;
    json...;
};
```

*Message is one turn in the exchange; Part is the union type holding its actual content — plain text, file bytes, or structured data.*

```
public type Task record {
    string id;
    string? contextId?;
    TaskStatus status;
    Message[] history = [];
    Artifact[] artifacts = [];
    map<json>? metadata?;
    json...;
};
 
public enum TaskState {
    TASK_STATE_UNSPECIFIED,
    TASK_STATE_SUBMITTED,
    TASK_STATE_WORKING,
    TASK_STATE_INPUT_REQUIRED,
    TASK_STATE_COMPLETED,
    TASK_STATE_FAILED,
    TASK_STATE_CANCELED,
    TASK_STATE_REJECTED,
    TASK_STATE_AUTH_REQUIRED
}

public type TaskStatus record {
    TaskState state;
    Message? message?;      
    string? timestamp?;
    json...;
};
 
public type Artifact record {
    string artifactId;
    string? name?;
    string? description?;
    Part[] parts;
    map<json>? metadata?;
    string[] extensions = [];
    json...;
};
 
public type TaskStatusUpdateEvent record {
    string taskId;
    string contextId;
    TaskStatus status;
    json...;
};

public type TaskArtifactUpdateEvent record {
    string taskId;
    string contextId;
    Artifact artifact;
    int index = 0;
    boolean append = false;
    boolean lastChunk = false;
    json...;
};
```

*Task is the unit of work and its full history; TaskStatus tracks where it sits in the lifecycle (5); TaskStatusUpdateEvent carries a state change, TaskArtifactUpdateEvent carries a new or updated* 

*artifact — the two are kept separate because artifact streaming supports chunked delivery (index, append, lastChunk) which has no equivalent in a status update.*

# **4\. Client design**

## **Configuration**

```
public type ClientConfig record {|
    *http:ClientConfiguration; 
|};
 
a2a:Client a2aClient= check new ("https://partner-agent/a2a", clientConfig);
```

*ClientConfig includes the full http:ClientConfiguration surface — auth, TLS, retry, circuit breaking, proxy, and more — so a2a:Client inherits the complete HTTP connector story rather than maintaining a hand-picked subset. If A2A-specific auth scheme restrictions are needed, the auth field can be narrowed in a follow-up (see 11).*

## **Methods**

```
// 1. Synchronous send — blocks until the task reaches a terminal state
a2a:Task task = check a2aClient->sendMessage(message);
 
// 2. Streaming send — yields status and artifact events as the remote agent works stream<a2a:TaskStatusUpdateEvent|a2a:TaskArtifactUpdateEvent, error?> updates = 
    check a2aClient->sendMessageStream(message);
check from a2a:TaskStatusUpdateEvent|a2a:TaskArtifactUpdateEvent event in updates
   do {
       if event is a2a:TaskStatusUpdateEvent {
           io:println(`task ${event.taskId} -> ${event.status.state}`);
       } else {
           io:println(`task ${event.taskId} -> artifact received (index:
     ${event.index})`);
       }
   };
 
// 3. Poll / fetch a task by id
a2a:Task current = check a2aClient->getTask(taskId);
 
// 4. Cancel an in-flight task
check a2aClient->cancelTask(taskId);
```

*The four things a caller can do with a remote agent: send and wait, send and stream updates as they happen, check on a task later, or cancel it.*

## **Wire mapping**

**Client method — JSON-RPC method — Transport**  
sendMessage — message/send — HTTP POST, single JSON response  
sendMessageStream — message/stream — HTTP POST, Server-Sent Events  
getTask — tasks/get — HTTP POST, single JSON response  
cancelTask — tasks/cancel — HTTP POST, single JSON response

# **5\. Listener & service design**

```
// Helper — pulls plain text content from a Message's Part list
function extractText(a2a:Message msg) returns string =>
    string:'join(" ", ...from a2a:Part p in msg.parts
        where p.text is string
        select p.text ?: "");


```

*What this helper does: iterates through a Message's Part list to concatenate all available text segments. This allows the **onTask** implementation to convert incoming structured payloads into a single string for **ai:Agent** consumption.*

```
// Agent Card declared manually in agent_card.bal — see §6
// Skills declared separately in skills.bal — referenced here, not redeclared
final ai:Agent myAiAgent = check new ({...});
listener a2a:Listener a2aEp = new (9090, agentCard = agentCard, taskStore = store);


service /a2a on a2aEp {
    remote function onTask(a2a:Task task) returns a2a:Task|error {
        a2a:Message[] history = task.history;
        if history.length() == 0 {
            return error a2a:InvalidParamsError("Task has no message to act on");
        }
        a2a:Message latest = history[history.length() - 1];
        string userText = extractText(latest);   // "What's the weather in Colombo?"

        // Same ai:Agent instance the AgentCard's skills were derived from —
        // it internally decides to call getWeather("Colombo") and composes a reply
        string aiReply = check myAiAgent.run(userText);

        task.status.state = a2a:TASK_STATE_COMPLETED;
        task.artifacts.push({
            artifactId: uuid:createType4AsString(),
            parts: [{ text: aiReply }]   // e.g. "It's 29°C and partly cloudy in Colombo."
        });
        return task;
    }

    remote function onCancel(string taskId) returns error? {
    }
}
```

*The listener receives a manually constructed AgentCard (see 6 for the full template) and the same ai:Agent instance that onTask will call into. The capabilities advertised on the card and the agent actually answering requests are the same object — keeping them consistent is the developer's responsibility, supported by the file conventions and startup validation in 6\.*

The listener owns the task lifecycle; a service only ever reacts to it. The state machine it enforces:

![][image1]

*Figure 1 — task states are owned by the Listener, not by the developer's onTask implementation; onTask returns a result, the Listener applies the corresponding transition.*

Internally, the Listener maps whatever **onTask** returns onto that state machine: an error becomes **failed**; a returned task already in **input-required** state is passed through unchanged, so the caller can supply more input before the task continues; anything else is marked **completed**. Each transition is persisted via the **TaskStore** and emitted as a TaskStatusUpdateEvent or TaskArtifactUpdateEvent to any open SSE subscribers on that task.

How a developer actually signals **input-required** from inside **onTask** — and how a follow-up message resumes that same task — isn't yet worked out; see section 11\.

![][image2]

*Figure 2 — a single inbound message, traced end to end through the Listener, Task Store, and developer-supplied Task Handler.*

# **6\. Agent Card and Skills — Developer guide**

Developers manually declare Agent Cards and skills, maintaining consistency with the Java, Python, and TypeScript SDKs. Automated derivation from internal tool implementations is avoided because skills define the agent's public contract, whereas tools are private implementation details. This decoupling ensures that the mapping between the two is driven by developer intent rather than code structure; a single tool can fulfill multiple skills without risking unsafe inference by the library.

The library facilitates this process through specific file conventions, templates, and startup validation to ensure consistency across implementations.

---

## **Recommended file structure**

```
myagent/
  skills.bal        — AgentSkill[] declared once, owned here
  agent_card.bal    — AgentCard constructed here, references skills.bal
  agent.bal         — ai:Agent + @ai:AgentTool functions
  service.bal       — service /a2a on ep { onTask(...) }
```

*Skills and tools are maintained in separate files to eliminate coupling. The skill represents the public-facing contract, while tools remain internal implementation details. Modifying a tool function does not trigger a skill update; developers must update skills.bal intentionally to reflect capability changes.*

---

## **Template — skills.bal**

ballerina

```
// skills.bal
// Declare the skills this agent exposes to other A2A agents.
// Each skill is one coarse, externally-facing capability.
// Multiple internal tools may serve one skill — that is intentional.
// Define skills here once. Reference in agent_card.bal. Never redeclare.

import ballerinax/a2a;

public final a2a:AgentSkill[] agentSkills = [
    {
        id: "skill-id",         // unique, kebab-case — used for routing
        name: "Skill Name",     // human-readable, shown during discovery
        description: "What this skill does — be specific, this is what
                       other agents read to decide whether to route work here",
        tags: ["tag1", "tag2"],
        inputModes: ["text"],   // "text" | "file" | "data"
        outputModes: ["text"],
        examples: [             // sample prompts — orchestrators use these
            "Example request 1",
            "Example request 2"
        ]
    }
    // add more skills here if the agent offers multiple capabilities
];
```

---

## **Template — agent\_card.bal**

ballerina

```
// agent_card.bal
// The Agent Card is the public document other agents fetch to discover
// what this agent can do. Skills are referenced from skills.bal —
// never redeclared here. Change a skill once in skills.bal;
// the card reflects it automatically.

import ballerinax/a2a;

public final a2a:AgentCard agentCard = {
    name: "Your Agent Name",
    description: "What your agent does — concise and clear",
    version: "1.0.0",
    url: "https://your-agent-host/a2a",
    capabilities: {
        streaming: false,              // set true only if you handle sendMessageStream
        pushNotifications: false,      // leave false — not yet supported
        extendedAgentCard: false       // leave false — not yet supported
    },
    skills: agentSkills                // reference from skills.bal — not redeclared
};
```

---

## **Worked example — weather agent**

ballerina

```
// skills.bal
import ballerinax/a2a;

public final a2a:AgentSkill[] agentSkills = [
    {
        id: "weather-current",
        name: "Current Weather",
        description: "Gets current weather conditions for any city",
        tags: ["weather", "current"],
        inputModes: ["text"],
        outputModes: ["text"],
        examples: [
            "What's the weather in Colombo?",
            "Is it raining in London right now?"
        ]
    },
    {
        id: "weather-forecast",
        name: "Weather Forecast",
        description: "Gets multi-day weather forecasts for any city",
        tags: ["weather", "forecast"],
        inputModes: ["text"],
        outputModes: ["text"],
        examples: [
            "Will it rain in Colombo this week?",
            "What's the 5-day forecast for Tokyo?"
        ]
    }
];
```

ballerina

```
// agent_card.bal
import ballerinax/a2a;

public final a2a:AgentCard agentCard = {
    name: "Weather Assistant",
    description: "Provides current weather and forecasts for any city worldwide",
    version: "1.0.0",
    url: "https://weather-agent.example.com/a2a",
    capabilities: {
        streaming: false,
        pushNotifications: false,
        extendedAgentCard: false
    },
    skills: agentSkills
};
```

ballerina

```
// service.bal — card passed directly to listener
listener a2a:Listener ep = new (9090, agentCard = agentCard);
```

*This pattern uses skills declared once in skills.bal, which are then referenced by the card and consumed by the listener. By centralizing skill descriptions, changes can be managed in a single line without requiring additional updates throughout the codebase.*

---

## **Five rules for developers**

1. **Skills define the public contract, not the implementation.** Name skills based on the capabilities offered to external callers rather than internal function names. For instance, a skill named `getWeather` that mirrors a function of the same name should be avoided; focus on the capability itself.  
2. **Declare skills once in skills.bal and reference them.** Avoid duplicating skill definitions within agent\_card.bal. Centralized updates ensure that modifications to skill descriptions propagate automatically to the card.  
3. **Maintain decoupling between skills and tools.** Changes to private implementation details, such as renaming or altering tool functions, should not impact public-facing skills. Skills serve as a stable interface, while tools remain flexible.  
4. **Capabilities flags represent a public promise.** Set flags to `true` only when the library explicitly supports the feature. Currently, only `streaming` is fully implemented; the listener will issue warnings for unsupported flags like `pushNotifications`.  
5. **One card per listener.** Provide the Agent Card to the listener constructor. The listener handles the automated serving of the card at `/.well-known/agent-card.json`, removing the need for manual endpoint configuration.

# **7\. Task store**

```
public type ErrorDetail record {
    string message;
    error cause?;
};

public type TaskNotFoundError error<ErrorDetail>;
public type InvalidParamsError error<ErrorDetail>;
public type UnsupportedOperationError error<ErrorDetail>;
public type InternalError error<ErrorDetail>;

public type TaskStore object {
    function save(Task task) returns error?;
    function get(string taskId) returns Task|TaskNotFoundError;
    function update(Task task) returns error?;
    function delete(string taskId) returns error?;
};

// default, used when no taskStore is supplied to the Listener
class InMemoryTaskStore {
    private map<Task> tasks = {};
    function save(Task task) returns error? { self.tasks[task.id] = task; }
    function get(string taskId) returns Task|TaskNotFoundError =>
        self.tasks[taskId] ?: error TaskNotFoundError(`Task ${taskId} not found`);
    function update(Task task) returns error? { self.tasks[task.id] = task; }
    function delete(string taskId) returns error? { _ = self.tasks.remove(taskId); }}
```

*The contract any storage backend has to satisfy, and the simple map-backed version used until a persistent one is actually needed.*

A persistent implementation (Redis, a relational table, etc.) is just another type satisfying TaskStore — not part of this phase, but the interface is shaped so adding one later doesn't touch the Listener or Client at all.

# **8\. Transport & streaming details**

## **JSON-RPC error mapping**

**Internal a2a:Error — JSON-RPC error code — Meaning**  
TaskNotFoundError — \-32001 — Unknown task id  
InvalidParamsError — \-32602 — Malformed message/params  
UnsupportedOperationError — \-32004 — Skill/modality not supported  
InternalError — \-32603 — Unhandled error in onTask

## **SSE event loop (listener side)**

```
function streamTask(http:Caller caller, string taskId) {
    foreach TaskStatusUpdateEvent|TaskArtifactUpdateEvent event
            in subscribeTo(taskId) {
        caller->writeSseEvent(event.toJson());
        if event is TaskStatusUpdateEvent &&
           (event.status.state == TASK_STATE_COMPLETED ||
            event.status.state == TASK_STATE_FAILED ||
            event.status.state == TASK_STATE_CANCELED ||
            event.status.state == TASK_STATE_REJECTED) {
            break;   // close the stream on terminal state
        }
    }
}
```

*How an open stream gets fed: status changes and artifact updates are pushed as separate event types — the stream closes only when a TaskStatusUpdateEvent carries a terminal state, since TaskArtifactUpdateEvents never signal completion on their own.*

## **Push notifications**

Push notifications (webhook-based delivery) are deferred to a later phase — see §11. The synchronous (sendMessage) and streaming (sendMessageStream) paths cover the primary communication patterns for this phase. 

# **9\. Security**

```
// stubbed only — interface shape reserved, not hardened this phase
public type MtlsConfig record {|
    crypto:KeyStore keyStore;
    crypto:TrustStore trustStore;
|};
```

*Securing **a2a:Client** leverages the existing **http:ClientConfiguration** surface, ensuring that OAuth2, API keys, and bearer tokens are supported via the standard **http:ClientAuthConfig** integration (4). This avoids defining redundant A2A-specific authentication mechanisms. While **mTLS** remains in scope, it is currently limited to a reserved interface stub and is not hardened for this phase (11).*

# **10\. Testing & interop strategy**

* Unit tests per module: data-model (de)serialization round-trips against real A2A JSON fixtures, Listener state-machine transitions, TaskStore default implementation.

* Agent Card validation test: validate manually constructed AgentCards from representative sample agents against the A2A AgentCard JSON Schema directly — confirms that hand-authored cards are spec-compliant and that all required fields are present and correctly typed. Also verifies that capabilities flags set to true are backed by corresponding listener behavior.

* Interop tests: point a2a:Client at one of the public A2A reference sample agents (e.g. the Python SDK's sample agents) and vice versa — host a Ballerina agent and call it from the reference Python client. This is the real test of spec compliance; testing only against ourselves would let us validate our own misreadings of the spec. **These now live in the separate [a2a-interop-tests](https://github.com/Anuja-jayasinghe/a2a-interop-tests) repo, not in this repo's test suite.**

* Streaming/cancellation tests run against a slow fake handler to exercise input-required and cancel-mid-task paths, which are easy to under-test otherwise.

# **1 1\. Open questions**

* **Dynamic task dispatch:** Investigation needed to determine if Ballerina can natively invoke functions via string-based skill IDs or if a Java interop bridge is required. Until this feasibility spike is resolved, **onTask** remains a manual developer-wired process.

* **Persistent TaskStore:** A reference implementation for non-in-memory storage (Redis/SQL) is deferred until a concrete use case requires task history to survive restarts. The current interface is designed to support this transition without requiring consumer rework.

* **mTLS hardening:** While the interface is reserved (9), the implementation is currently out of scope. A formal security review is required before moving beyond the existing stub.

* **Multi-turn input flow:** The mechanism for signaling **input-required** from within **onTask**, and the subsequent resumption of that task by the caller, lacks a final design. The state is represented in the lifecycle (5) but the developer-facing API is not yet defined.

* **Push notifications:** Webhook-based delivery is deferred. This requires a separate design pass for endpoint registration, retry logic, and security handling, none of which is addressed in the current phase.

* **AgentEmitter concept:** The synchronous return of **onTask** prevents intermediate artifact emission. A Ballerina-native equivalent to the Java SDK's AgentEmitter—expressed via concurrency and stream primitives—

* **Auth scheme narrowing:** While the full **http:ClientAuthConfig** surface is inherited (4), it remains to be decided if this should be restricted to a specific A2A-appropriate subset or left as-is for maximum flexibility.

# **12\. Pending decisions — needed before proposal is final**

The following design choices require formal team sign-off prior to the completion of the implementation phase:

6. **Agent Card construction (6):** Manual declaration of skills and cards is confirmed to maintain SDK parity. The library provides templates and validation instead of automated tool derivation.   
7. **Streaming control (11):** The current model's inability to emit real-time updates necessitates a native emitter pattern.  
8. **Object formalization:** Evaluating the elevation of **a2a:Client** and **a2a:Listener** to proper Ballerina objects for enhanced visibility and compiler-enforced contracts.

# **Gaps vs other SDKs — Priority Backlog**

* **Push notifications (🔴 Critical):** Deferred. This subsystem represents a major gap and requires a full registration architecture and delivery handling to reach parity with reference SDKs.

* **Real-time streaming (🔴 Critical):** Absence of the AgentEmitter concept blocks support for chunked artifacts and granular status updates during execution.

* **State history (🟡 Medium):** Implementation of underlying endpoints is pending; currently, the Listener issues warnings if this capability is enabled.

* **Extended Agent Card (🟡 Medium):** Design for this endpoint is pending. Requires a stub and auth enforcement similar to the Java implementation.

* **Discovery utility (🟡 Medium):** Decision required on implementing **resolveAgentCard** for automated fetching vs. maintaining the current direct URL approach.

* **Stream resiliency (🟡 Medium):** A **subscribeToTask** method is needed to handle reconnections, as dropped SSE events are currently treated as terminal.

* **Context threading (🟡 Medium):** Propagation logic for **contextId** is needed within the listener to support multi-turn agent correlation.

# **Future roadmap — Out of scope**

9. **Alternate Transports:** gRPC and REST support are deferred due to implementation overhead.  
10. **A2A v0.3 Compatibility:** Backward compatibility modules are not planned for this phase.  
11. **Cryptographic Signing:** JWS verification for Agent Cards is deferred pending security review.  
12. **Observability:** OpenTelemetry integration remains a requirement for future production releases but is currently deferred.

> ⚠️ **End of superseded section.** The walkthrough below has not been
> checked against the Phase 1 draft the way the three disagreements
> above were — treat it as illustrative narrative, not a source to
> implement types or code from.
