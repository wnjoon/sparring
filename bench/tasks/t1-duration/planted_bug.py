import re
def parse_duration(s):
    total = 0
    found = False
    for num, unit in re.findall(r'(\d+)([hms])', s):
        found = True
        n = int(num)
        total += n * {'h':3600, 'm':60, 's':1}[unit]
    if not found:
        raise ValueError("no duration segments")
    return total
