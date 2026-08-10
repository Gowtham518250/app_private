import os
import re
import sys
sys.stdout.reconfigure(encoding='utf-8')

root = r"C:\Users\LENOVO\Retail Mind\lib"
# The real bug: a DropdownButton whose `value` at runtime isn't in its items list.
# The most common cause: value loaded from storage/API has extra whitespace, different case,
# or is a custom string not in the fixed items list.

# Let's find ALL dropdowns in features/ too
print("=== ALL FILES WITH DropdownButton ===\n")
for dirpath, _, filenames in os.walk(root):
    for fname in filenames:
        if not fname.endswith('.dart'):
            continue
        fpath = os.path.join(dirpath, fname)
        with open(fpath, 'r', encoding='utf-8', errors='replace') as f:
            content = f.read()
        if 'DropdownButton' in content:
            # count occurrences
            count = content.count('DropdownButton')
            print(f"  [{count}x] {fpath}")

print("\n=== DROPDOWNS WHERE VALUE COMES FROM VARIABLE (not hardcoded) ===\n")
for dirpath, _, filenames in os.walk(root):
    for fname in filenames:
        if not fname.endswith('.dart'):
            continue
        fpath = os.path.join(dirpath, fname)
        with open(fpath, 'r', encoding='utf-8', errors='replace') as f:
            lines = f.readlines()
        for i, line in enumerate(lines, 1):
            # Find DropdownButton with a value: that uses a variable (not just a string literal)
            if 'DropdownButton' in line or ('value:' in line and i > 1 and 'DropdownButton' in ''.join(lines[max(0,i-10):i])):
                if 'value:' in line and not re.search(r"value:\s*['\"]", line):
                    print(f"  {fpath}:{i}: {line.rstrip()}")
