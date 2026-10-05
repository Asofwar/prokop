// The server chosen in each selector, kept across a reboot (C4).
//
// sing-box keeps the selection in its cache file, which lives in /tmp and
// is gone after a reboot: every selector then starts on its default. This
// small map "group -> tag" on flash brings the choice back after a start
// that found no cache file. It is written only when a choice changed
// (flash wear), through a checked rename: a choice lost to a power cut is
// not worth a sync, and a torn file reads as no choices. A group or a tag
// that the new configuration no longer has is skipped on restore.

let fs = require("fs");
let durable = require("core.durable");

const CHOICES_FILE = getenv("PROKOP_SELECTOR_CHOICES_FILE") || "/etc/prokop/selector-choices.json";
// Groups come and go with sections and subscriptions: the oldest choices
// are dropped beyond this.
const MAX_CHOICES = 256;

function valid_name(value) {
    return type(value) == "string" && value != "" && length(value) <= 512;
}

function read_choices() {
    let data = fs.readfile(CHOICES_FILE);
    let parsed = null;
    if (data != null) {
        try {
            parsed = json(data);
        }
        catch (e) {
            parsed = null;
        }
    }

    let result = {};
    if (type(parsed) != "object")
        return result;
    for (let group, tag in parsed)
        if (valid_name(group) && valid_name(tag))
            result[group] = tag;
    return result;
}

// Merges choices ({ group: tag }) into the saved map. A choice made again
// moves to the end, so the oldest go first beyond MAX_CHOICES. True when
// the file holds the choices afterwards.
function record_choices(choices) {
    if (type(choices) != "object")
        return false;

    let saved = read_choices();
    let merged = { ...saved };
    let changed = false;
    for (let group, tag in choices) {
        if (!valid_name(group) || !valid_name(tag))
            continue;
        if (saved[group] == tag)
            continue;
        delete merged[group];
        merged[group] = tag;
        changed = true;
    }
    if (!changed)
        return true;

    let groups = keys(merged);
    for (let i = 0; i < length(groups) - MAX_CHOICES; i++)
        delete merged[groups[i]];

    let dir = fs.dirname(CHOICES_FILE);
    if (fs.stat(dir) == null && !fs.mkdir(dir, 0755))
        return false;
    return durable.checked_replace(durable.temp_path(CHOICES_FILE), CHOICES_FILE,
        sprintf("%J\n", merged), 0600);
}

return { read_choices, record_choices, CHOICES_FILE, MAX_CHOICES };
