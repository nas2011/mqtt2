// Copyright (C) 2026 Nick Sexson. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

/**
Topic filter matching logic.
*/

/**
Returns true if the given [topic] matches the [filter].

The [filter] may contain MQTT wildcard characters per §4.7 of the MQTT 5.0 spec:
- `+` matches exactly one topic level.
- `#` matches zero or more remaining levels and must appear as the last level.

# Examples
```
match-topic "sport/+/player1" "sport/tennis/player1"  // true
match-topic "sport/#" "sport/tennis/finals"            // true
match-topic "sport/+" "sport/tennis/finals"            // false
```
*/
match-topic filter-parts/List topic/string -> bool:
  t-parts := topic.split "/"
  filter-parts.size.repeat: |i|
    f := filter-parts[i]
    if f == "#": return true
    if i >= t-parts.size: return false
    if f != "+" and f != t-parts[i]: return false
  return filter-parts.size == t-parts.size
