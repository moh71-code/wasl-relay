import os

files_to_dump = [
    'lib/main.dart',
    'lib/core/network/websocket_service.dart',
    'lib/core/database/database_helper.dart',
    'lib/screens/home_screen.dart',
    'lib/screens/chat_screen.dart',
    'lib/screens/qr_scanner_screen.dart',
    'lib/screens/settings_screen.dart',
    'lib/providers/settings_provider.dart',
    'wasl_relay.py'
]

output_file = "project_full_dump.txt"

with open(output_file, "w", encoding="utf-8") as outfile:
    for rel_path in files_to_dump:
        full_path = os.path.expanduser(rel_path)
        if not os.path.isabs(full_path):
            full_path = os.path.join(os.getcwd(), rel_path)
        
        outfile.write(f"\n=========================================\n")
        outfile.write(f"FILE: {rel_path}\n")
        outfile.write(f"=========================================\n\n")
        
        if os.path.exists(full_path):
            try:
                with open(full_path, "r", encoding="utf-8") as infile:
                    outfile.write(infile.read())
            except Exception as e:
                outfile.write(f"// Error reading file: {e}\n")
        else:
            outfile.write("// File not found!\n")

print(f"[+] تم توليد ملف الكود الموحد بنجاح: {output_file}")
