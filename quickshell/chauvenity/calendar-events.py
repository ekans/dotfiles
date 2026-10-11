#!/usr/bin/python3
# Streams calendar events to the bar's clock (Clock.qml and ClockPanel.qml).
#
# Reads them straight from Google Calendar and Microsoft 365, for every
# account added in GNOME Settings → Online Accounts with its Calendar switch
# on. Online Accounts keeps the sign-in and hands out short-lived access
# tokens over D-Bus, so this script never sees a password and stores nothing.
#
# Which calendars: for Google, the ones ticked in Google Calendar's own list.
# Microsoft Graph does not say which ones Outlook shows, so for Microsoft 365
# all of them, but those named in HIDDEN.
#
# Prints one JSON object per line, a whole snapshot each time it changes:
#
#     {"from": ms, "to": ms,                     # the stretch the events cover
#      "calendars": [{"name", "color"}],
#      "events": [{"calendar": index, "title", "location", "link",
#                  "start": ms, "end": ms, "allDay", "tentative"}],
#      "problems": ["david@example.com: could not read: …"]}
#
# Times are milliseconds since the epoch; an all-day event runs from local
# midnight to local midnight. Recurring events come expanded, one per
# occurrence — both servers do it — and cancelled or declined ones are left
# out. `tentative` is an event not answered yet, or accepted as tentative.
#
# Runs until the bar goes away. /usr/bin/python3 because it has the GObject
# bindings; the python3 on PATH may well not.

import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from zoneinfo import ZoneInfo

import gi

gi.require_version("Goa", "1.0")
from gi.repository import GLib, Goa  # noqa: E402

# How often every account is read again. Each read is a handful of requests
# per account.
REFRESH_MINUTES = 5
# Accounts change in bursts — signing in changes one several times — and one
# read follows the burst.
SETTLE_SECONDS = 2
# Microsoft 365 calendars to leave out, by name, e.g. "United States holidays".
HIDDEN = []

# Links worth a click on an event: its video call, for an event that only
# mentions it rather than saying where its call is.
MEETING_LINK = re.compile(
    r"https://(?:teams\.microsoft\.com|teams\.live\.com|meet\.google\.com"
    r"|[\w.-]*zoom\.us|app\.slack\.com/huddle)/[^\s<>\"']*")

GOOGLE = "https://www.googleapis.com/calendar/v3"
GRAPH = "https://graph.microsoft.com/v1.0"

# Outlook's named calendar colours, in the bar's palette. "auto" is what the
# account's default calendar has.
OUTLOOK_COLORS = {
    "auto": "#62a0ea", "lightBlue": "#62a0ea", "lightGreen": "#57e389",
    "lightOrange": "#ffa348", "lightGray": "#9a9996", "lightYellow": "#f8e45c",
    "lightTeal": "#5bc8af", "lightPink": "#dc8add", "lightBrown": "#cdab8f",
    "lightRed": "#f66151",
}


class Problem(Exception):
    pass


def month(today, delta):
    """Local midnight on the first of the month `delta` months from today's."""
    index = today.year * 12 + today.month - 1 + delta
    return datetime(index // 12, index % 12 + 1, 1)


def window(today):
    """Last month to three months ahead: the months the panel pages through
    most, read up front so that paging needs no round trip."""
    return month(today, -1), month(today, 4)


def local_zone():
    """The machine's time zone, by the IANA name Graph takes."""
    path = os.path.realpath("/etc/localtime")
    return path.split("zoneinfo/", 1)[1] if "zoneinfo/" in path else "UTC"


def millis(moment):
    return int(moment.timestamp() * 1000)


def local_day(text):
    """`2026-10-12` as local midnight."""
    return millis(datetime.strptime(text[:10], "%Y-%m-%d"))


def get(url, token, headers=None):
    request = urllib.request.Request(url, headers=dict(
        {"Authorization": f"Bearer {token}", "Accept": "application/json"}, **(headers or {})))
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        try:
            message = json.load(error).get("error", {}).get("message", "")
        except (ValueError, AttributeError):
            message = ""
        raise Problem(f"HTTP {error.code}" + (f": {message}" if message else "")) from None
    except (urllib.error.URLError, TimeoutError) as error:
        raise Problem(f"no answer: {getattr(error, 'reason', error)}") from None


def found_link(*texts):
    for text in texts:
        match = MEETING_LINK.search(text or "")
        if match:
            return match.group(0)
    return ""


# --- Google Calendar ---------------------------------------------------------

def google_pages(url, token):
    page = None
    while True:
        answer = get(url + (f"&pageToken={urllib.parse.quote(page)}" if page else ""), token)
        yield from answer.get("items", [])
        page = answer.get("nextPageToken")
        if not page:
            return


def google_event(item):
    # A working location is a label on the day, not an event.
    if item.get("status") == "cancelled" or item.get("eventType") == "workingLocation":
        return None
    me = next((a for a in item.get("attendees", []) if a.get("self")), {})
    reply = me.get("responseStatus")
    if reply == "declined":
        return None
    start, end = item.get("start", {}), item.get("end", {})
    all_day = "date" in start
    if all_day:
        begin, finish = local_day(start["date"]), local_day(end.get("date", start["date"]))
    else:
        begin = millis(datetime.fromisoformat(start["dateTime"]))
        finish = millis(datetime.fromisoformat(end.get("dateTime", start["dateTime"])))
    video = [p.get("uri", "") for p in item.get("conferenceData", {}).get("entryPoints", [])
             if p.get("entryPointType") == "video"]
    return {
        "title": item.get("summary", ""),
        "location": item.get("location", ""),
        "link": item.get("hangoutLink") or (video[0] if video else "")
            or found_link(item.get("location"), item.get("description")),
        "start": begin,
        "end": max(finish, begin),
        "allDay": all_day,
        "tentative": reply in ("tentative", "needsAction"),
    }


def read_google(token, start, end):
    calendars, events = [], []
    listed = google_pages(f"{GOOGLE}/users/me/calendarList?fields="
                          + urllib.parse.quote("items(id,summary,summaryOverride,backgroundColor,"
                                               "selected,hidden,primary),nextPageToken"), token)
    # The primary calendar first, the others as Google lists them.
    for item in sorted(listed, key=lambda c: not c.get("primary")):
        if not item.get("selected") or item.get("hidden"):
            continue
        query = urllib.parse.urlencode({
            "timeMin": start.astimezone().isoformat(),
            "timeMax": end.astimezone().isoformat(),
            "singleEvents": "true",
            "maxResults": 2500,
            "fields": "items(status,eventType,summary,location,description,start,end,"
                      "attendees(self,responseStatus),hangoutLink,"
                      "conferenceData/entryPoints(entryPointType,uri)),nextPageToken",
        })
        url = f"{GOOGLE}/calendars/{urllib.parse.quote(item['id'], safe='')}/events?{query}"
        index = len(calendars)
        calendars.append({"name": item.get("summaryOverride") or item.get("summary", ""),
                          "color": item.get("backgroundColor", "")})
        for found in map(google_event, google_pages(url, token)):
            if found:
                found["calendar"] = index
                events.append(found)
    return calendars, events


# --- Microsoft 365 -----------------------------------------------------------

def graph_pages(url, token, headers=None):
    while url:
        answer = get(url, token, headers)
        yield from answer.get("value", [])
        url = answer.get("@odata.nextLink")


def graph_event(item, zone):
    reply = item.get("responseStatus", {}).get("response")
    if item.get("isCancelled") or reply == "declined":
        return None

    # Asked for in the machine's zone, so that an all-day event comes as
    # local midnights; in UTC it would start at 22:00 the day before.
    def moment(at):
        return millis(datetime.fromisoformat(at["dateTime"][:19]).replace(tzinfo=zone))

    begin, finish = moment(item["start"]), moment(item["end"])
    location = (item.get("location") or {}).get("displayName", "")
    return {
        "title": item.get("subject", ""),
        "location": location,
        "link": (item.get("onlineMeeting") or {}).get("joinUrl")
            or found_link(location, item.get("bodyPreview")),
        "start": begin,
        "end": max(finish, begin),
        "allDay": bool(item.get("isAllDay")),
        "tentative": reply in ("tentativelyAccepted", "notResponded"),
    }


def read_graph(token, start, end):
    zone_name = local_zone()
    zone = ZoneInfo(zone_name)
    prefer = {"Prefer": f'outlook.timezone="{zone_name}"'}
    calendars, events = [], []
    hidden = {name.lower() for name in HIDDEN}
    listed = graph_pages(f"{GRAPH}/me/calendars?$select=id,name,color,hexColor,isDefaultCalendar&$top=100", token)
    for item in sorted(listed, key=lambda c: not c.get("isDefaultCalendar")):
        if item.get("name", "").lower() in hidden:
            continue
        query = urllib.parse.urlencode({
            "startDateTime": start.astimezone().isoformat(),
            "endDateTime": end.astimezone().isoformat(),
            "$top": 500,
            "$select": "subject,start,end,isAllDay,isCancelled,location,onlineMeeting,"
                       "responseStatus,bodyPreview",
        })
        url = f"{GRAPH}/me/calendars/{urllib.parse.quote(item['id'], safe='')}/calendarView?{query}"
        index = len(calendars)
        calendars.append({"name": item.get("name", ""),
                          "color": item.get("hexColor") or OUTLOOK_COLORS.get(item.get("color"), "")})
        for found in (graph_event(e, zone) for e in graph_pages(url, token, prefer)):
            if found:
                found["calendar"] = index
                events.append(found)
    return calendars, events


# Online Accounts' provider types, and how to read each.
READERS = {"google": read_google, "ms_graph": read_graph}


# --- the feed ----------------------------------------------------------------

class Feed:
    def __init__(self):
        self.client = None
        # Account id -> what was last read from it: its calendars, their
        # events, and when. A failed read keeps it, so the events stay on
        # screen and the problem says how old they are.
        self.read = {}
        self.problems = []
        self.span = window(datetime.now())
        self.last = None
        self.settle = 0
        GLib.timeout_add_seconds(REFRESH_MINUTES * 60, self.refresh)
        self.refresh()

    def accounts(self):
        """Online Accounts' accounts. Asked again each round until goa-daemon
        answers, so the bar recovers from it starting late."""
        if self.client is None:
            try:
                self.client = Goa.Client.new_sync(None)
            except GLib.Error as error:
                self.problems.append(f"Online Accounts: {error.message}")
                return []
            for signal in ("account-added", "account-removed", "account-changed"):
                self.client.connect(signal, lambda *_: self.later())
        return self.client.get_accounts()

    def later(self):
        if self.settle:
            GLib.source_remove(self.settle)
        self.settle = GLib.timeout_add_seconds(SETTLE_SECONDS, self.settled)

    def settled(self):
        self.settle = 0
        self.refresh()
        return GLib.SOURCE_REMOVE

    def refresh(self):
        self.problems = []
        self.span = window(datetime.now())
        seen = set()
        for found in self.accounts():
            account = found.get_account()
            reader = READERS.get(account.props.provider_type)
            if reader is None or account.props.calendar_disabled or found.get_oauth2_based() is None:
                continue
            seen.add(account.props.id)
            self.read_account(found, account, reader)
        # A removed account takes its events with it.
        for gone in set(self.read) - seen:
            del self.read[gone]
        self.emit()
        return GLib.SOURCE_CONTINUE

    def read_account(self, found, account, reader):
        name = account.props.presentation_identity or account.props.provider_name
        try:
            if account.props.attention_needed:
                raise Problem("signed out, sign in again in Settings → Online Accounts")
            try:
                token, _ = found.get_oauth2_based().call_get_access_token_sync(None)
            except GLib.Error as error:
                raise Problem(f"no access token, sign in again in Settings → Online Accounts "
                              f"({error.message})") from None
            calendars, events = reader(token, *self.span)
        except Problem as problem:
            earlier = self.read.get(account.props.id)
            self.problems.append(f"{name}: could not read: {problem}"
                                 + (f"; events as of {earlier['at']:%H:%M}" if earlier else ""))
            return
        self.read[account.props.id] = {"calendars": calendars, "events": events, "at": datetime.now()}

    def snapshot(self):
        calendars, events = [], []
        for read in self.read.values():
            offset = len(calendars)
            calendars.extend(read["calendars"])
            events.extend(dict(e, calendar=e["calendar"] + offset) for e in read["events"])
        start, end = self.span
        return {
            "from": millis(start),
            "to": millis(end),
            "calendars": calendars,
            "events": events,
            "problems": self.problems,
        }

    def emit(self):
        line = json.dumps(self.snapshot(), ensure_ascii=False, separators=(",", ":"))
        if line == self.last:
            return
        self.last = line
        try:
            print(line, flush=True)
        except BrokenPipeError:
            # The bar went away.
            sys.exit(0)


def main():
    Feed()
    GLib.MainLoop().run()


if __name__ == "__main__":
    main()
