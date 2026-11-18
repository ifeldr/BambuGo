// Nessuna finestra di console su Windows.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    bambugo_lib::run()
}
