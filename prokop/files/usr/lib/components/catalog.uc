// The component actions: what components/action.uc component_action runs, by
// component. The action itself and the UI's background start
// (components/updates.uc component_action_async) both refuse any other, so a
// pair is valid input to both or to neither (UC-119).
const ACTIONS = {
    prokop: [ "check_update", "install" ],
    sing_box: [ "check_update", "install", "install_extended", "install_extended_compressed", "install_tiny", "install_stable" ],
    zapret: [ "check_update", "install", "remove" ],
    zapret2: [ "check_update", "install", "remove" ],
    byedpi: [ "check_update", "install", "remove" ],
    zapret_manager: [ "install", "remove" ],
    packet_steering: [ "enable", "restore" ],
    direct_proxy: [ "enable", "disable" ],
    torrserver: [ "check_update", "install", "remove" ],
    torrserver_direct: [ "enable", "disable" ]
};

// COMPONENT is the normalized name (sing_box, not sing-box).
function supported(component, action) {
    let actions = ACTIONS["" + (component ?? "")];
    return type(actions) == "array" && index(actions, "" + (action ?? "")) >= 0;
}

return { ACTIONS, supported };
