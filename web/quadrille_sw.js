// Quadrille rest-timer service worker.
//
// Registered at a narrow scope so it never conflicts with Flutter's own
// service worker. It does two things:
//   1. Schedules the "rest complete" notification with a TimestampTrigger when
//      the browser supports it — this fires even if the tab is later closed.
//      Where unsupported, the page's in-page timer handles it instead.
//   2. Focuses (or opens) Quadrille when the notification is tapped.
//
// Both the scheduled notification and the page fallback use the same tag, so
// if both happen to fire they coalesce into one notification instead of two.

const REST_TAG = 'quadrille-rest';

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));

self.addEventListener('message', (event) => {
  const data = event.data || {};
  if (data.type === 'scheduleRest') {
    if (!('TimestampTrigger' in self)) return; // page timer covers this browser
    const options = {
      body: data.body,
      tag: REST_TAG,
      renotify: true,
      requireInteraction: false,
      showTrigger: new TimestampTrigger(data.timestamp),
    };
    event.waitUntil(self.registration.showNotification(data.title, options));
  } else if (data.type === 'cancelRest') {
    event.waitUntil(
      self.registration
        .getNotifications({ tag: REST_TAG, includeTriggered: true })
        .then((list) => list.forEach((n) => n.close()))
        .catch(() => {})
    );
  }
});

// Web Push: the server sends this at the rest deadline, so it fires even when
// the tab is fully closed. Same tag as the in-page/triggered notification, so
// they coalesce into one.
self.addEventListener('push', (event) => {
  let data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch (e) {
    data = {};
  }
  const title = data.title || 'Rest complete';
  event.waitUntil(
    self.registration.showNotification(title, {
      body: data.body || 'Time for your next set.',
      tag: REST_TAG,
      renotify: true,
    })
  );
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil(
    self.clients
      .matchAll({ type: 'window', includeUncontrolled: true })
      .then((clientList) => {
        for (const client of clientList) {
          if ('focus' in client) return client.focus();
        }
        if (self.clients.openWindow) return self.clients.openWindow('/');
      })
  );
});
