# Azure Service Bus Walkthrough

A progressive, six-stage guide to understanding the Azure Service Bus emulator — AMQP 1.0 messaging, queues, topics, subscriptions, and how the emulator depends on SQL Server for state storage.

**Azure equivalent:** Azure Service Bus  
**Namespace:** `service-bus`

---

## Stage 1 — What the Service Bus emulator is

**Goal:** understand the architecture, the SQL dependency, and why the emulator is AMD64-only.

The Microsoft Service Bus emulator (`mcr.microsoft.com/azure-messaging/servicebus-emulator`) implements the full AMQP 1.0 protocol and the Service Bus REST management API. Applications using the Azure Service Bus SDK connect with `UseDevelopmentEmulator=true` in the connection string — no code changes beyond the connection string are needed.

```bash
# Confirm the emulator is running and healthy
kubectl get pod -n service-bus -l app=servicebus
kubectl get svc servicebus -n service-bus

# Check the health endpoint
kubectl exec -n toolbox deploy/toolbox -- \
  curl -s http://servicebus.service-bus.svc.cluster.local:5300/health
# Expect: healthy / 200 OK

# See the image — AMD64 only, runs via Rosetta on Apple Silicon
kubectl get deployment servicebus -n service-bus \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# mcr.microsoft.com/azure-messaging/servicebus-emulator:latest

# Read the env vars that wire Service Bus to the SQL backend
kubectl get deployment servicebus -n service-bus \
  -o jsonpath='{.spec.template.spec.containers[0].env}' | python3 -m json.tool | \
  python3 -c "import sys,json; [print(f'{e[\"name\"]}: {e.get(\"value\",\"<from secret>\")}') for e in json.load(sys.stdin)]"
# SQL_SERVER:           mssql.azure-sql.svc.cluster.local
# MSSQL_SA_PASSWORD:    AksLab!SqlDev1
# SQL_WAIT_INTERVAL:    30
# ACCEPT_EULA:          Y
# CONFIG_PATH:          /ServiceBus_Emulator/ConfigFiles/Config.json

# Verify the emulator can reach SQL
kubectl exec -n toolbox deploy/toolbox -- \
  nc -zv mssql.azure-sql.svc.cluster.local 1433
# succeeded
```

**Why SQL Server?** Azure Service Bus in production stores messages in a proprietary distributed log. The emulator replaces that with SQL Server for simplicity — it stores message queues, dead-letter queues, and subscription state in relational tables. This is why Azure SQL Edge must be running before the Service Bus emulator starts.

**The `Recreate` strategy:** like Azure SQL Edge, the Service Bus emulator uses `Recreate` to avoid split-brain state in SQL between two emulator pods.

**What you learn:** the Service Bus emulator is a thin AMQP/HTTP facade over SQL Server. Its SQL dependency is visible in the environment variables — making a dependency explicit in the pod spec is the Kubernetes-idiomatic way to document and enforce cross-service relationships.

---

## Stage 2 — Namespace, queue, and topic configuration

**Goal:** read and understand the `Config.json` that defines the messaging entities.

All queues, topics, and subscriptions are declared in a ConfigMap before the emulator starts. The emulator creates these entities in SQL on startup.

```bash
# Read the entity configuration
kubectl get configmap servicebus-config -n service-bus \
  -o jsonpath='{.data.Config\.json}' | python3 -m json.tool
```

The structure:

```json
{
  "UserConfig": {
    "Namespaces": [{
      "Name": "sbemulatorns",
      "Queues": [{
        "Name": "queue.1",
        "Properties": {
          "DefaultMessageTimeToLive": "PT1H",
          "LockDuration": "PT1M",
          "MaxDeliveryCount": 3,
          "RequiresDuplicateDetection": false
        }
      }],
      "Topics": [{
        "Name": "topic.1",
        "Subscriptions": [{
          "Name": "subscription.1",
          "Properties": { ... }
        }]
      }]
    }]
  }
}
```

**Key settings explained:**

| Property | Value | Meaning |
|----------|-------|---------|
| `DefaultMessageTimeToLive` | `PT1H` | Messages expire after 1 hour (ISO 8601 duration) |
| `LockDuration` | `PT1M` | A consumer has 1 minute to process and acknowledge before the message becomes visible again |
| `MaxDeliveryCount` | `3` | After 3 failed deliveries, the message moves to the dead-letter queue |
| `RequiresDuplicateDetection` | `false` | No deduplication — the same message ID can be sent multiple times |

**Add a new queue:**

```bash
# Edit the ConfigMap
kubectl edit configmap servicebus-config -n service-bus
# Add a new queue entry under "Queues": [...]

# Restart the emulator to reload the config
kubectl rollout restart deployment servicebus -n service-bus
kubectl rollout status deployment servicebus -n service-bus --timeout=60s
```

**What you learn:** unlike Azure Service Bus where you create queues via the portal or ARM templates, the emulator reads its entity list from a static file. Any change requires a pod restart — this is the one place where the emulator differs from production (Azure Service Bus creates queues dynamically without restarts).

---

## Stage 3 — Publishing a message to a queue

**Goal:** send a message via the AMQP 1.0 protocol and see it arrive in the queue.

The simplest way to interact with Service Bus from the cluster is with the `azure-servicebus` Python SDK or the `@azure/service-bus` npm package. From the toolbox pod:

```bash
# Install the azure-servicebus package temporarily (the toolbox has pip3)
kubectl exec -n toolbox deploy/toolbox -- \
  pip3 install azure-servicebus --quiet

# Send a message to queue.1
kubectl exec -n toolbox deploy/toolbox -- python3 - << 'EOF'
from azure.servicebus import ServiceBusClient, ServiceBusMessage

conn = (
    "Endpoint=sb://servicebus.service-bus.svc.cluster.local;"
    "SharedAccessKeyName=RootManageSharedAccessKey;"
    "SharedAccessKey=SAS_KEY_VALUE;"
    "UseDevelopmentEmulator=true;"
)

with ServiceBusClient.from_connection_string(conn) as client:
    with client.get_queue_sender("queue.1") as sender:
        msg = ServiceBusMessage("Hello from the cluster!", subject="test")
        sender.send_messages(msg)
        print("Message sent to queue.1")
EOF

# Verify the message landed — check the queue depth via the management API
kubectl exec -n toolbox deploy/toolbox -- \
  curl -s "http://servicebus.service-bus.svc.cluster.local:5300/\$servicebus/namespaces/sbemulatorns/queues/queue.1" | \
  python3 -m json.tool 2>/dev/null || \
  echo "(management API response format may vary by version)"

# Alternatively check Service Bus logs for the AMQP accept event
kubectl logs -n service-bus deploy/servicebus --tail=20
```

**Connection string fields:**

| Field | Value | Purpose |
|-------|-------|---------|
| `Endpoint` | `sb://servicebus.service-bus.svc.cluster.local` | AMQP host (port 5672) |
| `SharedAccessKeyName` | `RootManageSharedAccessKey` | SAS policy name (emulator accepts any) |
| `SharedAccessKey` | `SAS_KEY_VALUE` | The literal string accepted by the emulator |
| `UseDevelopmentEmulator` | `true` | Tells the SDK to skip TLS and use HTTP for management calls |

**What you learn:** `SAS_KEY_VALUE` is literally what you put in the connection string — the emulator does not validate the key value when `UseDevelopmentEmulator=true`. In production, the key is a real 256-bit HMAC secret used to sign requests.

---

## Stage 4 — Consuming messages from a queue

**Goal:** receive and acknowledge a message, and see what happens to unacknowledged messages.

```bash
# Receive the message sent in Stage 3
kubectl exec -n toolbox deploy/toolbox -- python3 - << 'EOF'
from azure.servicebus import ServiceBusClient

conn = (
    "Endpoint=sb://servicebus.service-bus.svc.cluster.local;"
    "SharedAccessKeyName=RootManageSharedAccessKey;"
    "SharedAccessKey=SAS_KEY_VALUE;"
    "UseDevelopmentEmulator=true;"
)

with ServiceBusClient.from_connection_string(conn) as client:
    with client.get_queue_receiver("queue.1", max_wait_time=5) as receiver:
        msgs = receiver.receive_messages(max_message_count=10, max_wait_time=5)
        for msg in msgs:
            print(f"Received: {str(msg)} | subject={msg.subject}")
            receiver.complete_message(msg)   # ← acknowledge: remove from queue
            print("Message completed (acknowledged)")
        if not msgs:
            print("No messages in queue")
EOF
```

**The lock-and-acknowledge pattern:**

```bash
# Send a message, then receive but NOT acknowledge it
kubectl exec -n toolbox deploy/toolbox -- python3 - << 'EOF'
from azure.servicebus import ServiceBusClient, ServiceBusMessage
import time

conn = (
    "Endpoint=sb://servicebus.service-bus.svc.cluster.local;"
    "SharedAccessKeyName=RootManageSharedAccessKey;"
    "SharedAccessKey=SAS_KEY_VALUE;"
    "UseDevelopmentEmulator=true;"
)

with ServiceBusClient.from_connection_string(conn) as client:
    # Send
    with client.get_queue_sender("queue.1") as sender:
        sender.send_messages(ServiceBusMessage("lock demo"))

    # Receive but abandon (simulates a consumer crash)
    with client.get_queue_receiver("queue.1", max_wait_time=5) as receiver:
        msgs = receiver.receive_messages(max_message_count=1, max_wait_time=5)
        for msg in msgs:
            print(f"Received (delivery count: {msg.delivery_count})")
            receiver.abandon_message(msg)   # ← returns message to the queue
            print("Abandoned — message will reappear")
EOF

# Receive again — delivery_count will be 1
# After MaxDeliveryCount (3) failures, the message moves to queue.1/$DeadLetterQueue
```

**What you learn:** the lock-and-acknowledge pattern is the foundation of at-least-once delivery. A consumer holds a lock (`LockDuration = PT1M`) while processing. If it crashes or abandons, the message becomes visible again. After `MaxDeliveryCount` failures, the message moves to the dead-letter queue for manual inspection — a critical pattern for production message processing.

---

## Stage 5 — Topics and subscriptions

**Goal:** send a message to a topic and receive it from a subscription — the pub/sub pattern.

Topics allow one message to be delivered to multiple independent subscribers. Each subscriber has its own subscription queue, and each subscription can have filter rules to receive only certain messages.

```bash
# Publish to topic.1
kubectl exec -n toolbox deploy/toolbox -- python3 - << 'EOF'
from azure.servicebus import ServiceBusClient, ServiceBusMessage

conn = (
    "Endpoint=sb://servicebus.service-bus.svc.cluster.local;"
    "SharedAccessKeyName=RootManageSharedAccessKey;"
    "SharedAccessKey=SAS_KEY_VALUE;"
    "UseDevelopmentEmulator=true;"
)

with ServiceBusClient.from_connection_string(conn) as client:
    with client.get_topic_sender("topic.1") as sender:
        msgs = [
            ServiceBusMessage("order-placed", subject="order", application_properties={"priority": "high"}),
            ServiceBusMessage("payment-received", subject="payment"),
        ]
        sender.send_messages(msgs)
        print(f"Sent {len(msgs)} messages to topic.1")
EOF

# Receive from subscription.1 (every message sent to topic.1 lands here)
kubectl exec -n toolbox deploy/toolbox -- python3 - << 'EOF'
from azure.servicebus import ServiceBusClient

conn = (
    "Endpoint=sb://servicebus.service-bus.svc.cluster.local;"
    "SharedAccessKeyName=RootManageSharedAccessKey;"
    "SharedAccessKey=SAS_KEY_VALUE;"
    "UseDevelopmentEmulator=true;"
)

with ServiceBusClient.from_connection_string(conn) as client:
    with client.get_subscription_receiver(
        topic_name="topic.1",
        subscription_name="subscription.1",
        max_wait_time=5
    ) as receiver:
        for msg in receiver.receive_messages(max_message_count=10, max_wait_time=5):
            print(f"[subscription.1] {str(msg)} | subject={msg.subject}")
            receiver.complete_message(msg)
EOF
```

**Queues vs topics:**

| Concept | Queue | Topic + Subscription |
|---------|-------|---------------------|
| Consumers | One consumer at a time | Many independent consumers |
| Pattern | Work distribution (one worker handles each job) | Event fan-out (each subscriber gets a copy) |
| Azure equivalent | Azure Service Bus Queue | Azure Service Bus Topic |

**What you learn:** topics enable the event-driven pattern where a single producer (e.g., an order service) publishes an event and multiple consumers (inventory service, email service, analytics) each receive a copy independently. Adding a new subscriber does not change the publisher — only a new subscription is needed.

---

## Stage 6 — Private Link DNS simulation

**Goal:** understand how `myservicebus.privatelink.servicebus.windows.net` resolves to the emulator.

```bash
# Resolve the private link hostname
kubectl exec -n toolbox deploy/toolbox -- \
  nslookup myservicebus.privatelink.servicebus.windows.net
# Expect: the Service Bus ClusterIP

# The corp.internal alias also works
kubectl exec -n toolbox deploy/toolbox -- \
  nslookup servicebus.corp.internal
# Expect: same ClusterIP

# The Event Hub private link name resolves to the same emulator
# (Event Hub uses the AMQP 1.0 protocol — same as Service Bus)
kubectl exec -n toolbox deploy/toolbox -- \
  nslookup myeventhub.privatelink.servicebus.windows.net
# Expect: same ClusterIP

# Test connectivity via the private link hostname
kubectl exec -n toolbox deploy/toolbox -- \
  nc -zv myservicebus.privatelink.servicebus.windows.net 5672
# AMQP port — succeeded
```

**Why Event Hub shares the Service Bus zone:** Azure Event Hub is built on AMQP 1.0 and uses the same `privatelink.servicebus.windows.net` private DNS zone as Service Bus. In the lab, both `myservicebus` and `myeventhub` point to the Service Bus emulator because the AMQP protocol is compatible.

**What you learn:** the private link DNS simulation collapses two Azure services (Service Bus and Event Hub) onto one emulator because they share the same protocol and DNS zone. This is acceptable in a lab but would not reflect production topology where they are separate managed resources.

---

## Quick reference

| Task | Command |
|------|---------|
| Health check | `curl -s http://servicebus.service-bus.svc.cluster.local:5300/health` |
| Service Bus logs | `kubectl logs -n service-bus deploy/servicebus -f` |
| Edit queues/topics | `kubectl edit configmap servicebus-config -n service-bus` then `kubectl rollout restart deployment servicebus -n service-bus` |
| In-cluster endpoint | `sb://servicebus.service-bus.svc.cluster.local` |
| Private link hostname | `myservicebus.privatelink.servicebus.windows.net:5672` |
| Connection string | `Endpoint=sb://servicebus.service-bus.svc.cluster.local;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=SAS_KEY_VALUE;UseDevelopmentEmulator=true;` |

See also: [service-bus.md](../services/service-bus.md), [azure-sql-walkthrough.md](azure-sql-walkthrough.md), [dns-walkthrough.md](dns-walkthrough.md)
