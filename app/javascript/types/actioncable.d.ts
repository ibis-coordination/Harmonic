declare module "@rails/actioncable" {
  interface Subscription {
    unsubscribe(): void
    perform(action: string, data?: Record<string, unknown>): void
  }

  interface SubscriptionCallbacks {
    received?(data: unknown): void
    connected?(): void
    disconnected?(): void
    rejected?(): void
  }

  interface Subscriptions {
    create(
      channel: string | Record<string, unknown>,
      callbacks: SubscriptionCallbacks,
    ): Subscription
  }

  interface Consumer {
    subscriptions: Subscriptions
    disconnect(): void
  }

  export function createConsumer(url?: string): Consumer
}
