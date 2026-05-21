const { ServiceBusClient } = require("@azure/service-bus");

const connectionString = process.env.SERVICE_BUS_CONNECTION_STRING;
const queueName = process.env.QUEUE_NAME || "queue.1";
// Simulate work so messages don't drain instantly — useful for watching KEDA hold replicas up
const processingDelayMs = parseInt(process.env.PROCESSING_DELAY_MS || "2000", 10);

if (!connectionString) {
  console.error("SERVICE_BUS_CONNECTION_STRING is required");
  process.exit(1);
}

async function main() {
  const client = new ServiceBusClient(connectionString);
  const receiver = client.createReceiver(queueName, { receiveMode: "peekLock" });

  console.log(`[processor] Connected — listening on queue '${queueName}'`);

  const messageHandler = async (message) => {
    console.log(`[processor] Received: ${JSON.stringify(message.body)}`);
    await new Promise((r) => setTimeout(r, processingDelayMs));
    await receiver.completeMessage(message);
    console.log(`[processor] Completed after ${processingDelayMs}ms`);
  };

  const errorHandler = async (err) => {
    console.error("[processor] Error:", err.message);
  };

  receiver.subscribe({ processMessage: messageHandler, processError: errorHandler });

  const shutdown = async () => {
    console.log("[processor] Shutting down...");
    await receiver.close();
    await client.close();
    process.exit(0);
  };

  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
}

main().catch((err) => {
  console.error("[processor] Fatal:", err.message);
  process.exit(1);
});
