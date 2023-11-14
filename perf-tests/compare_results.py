# Compare results in the following format:
# [ '8034-2', 4771.30, 12436.71, 16177.24, 17847.10, 17432.94, 19117.39, 23005.24, 24081.72, ],
# [ '8034-2', 3681.59, 11069.02, 15603.86, 17141.30, 18584.88, 17440.19, 16558.88, 15951.62, ],
# [ '8034-2', 4297.50, 6867.19, 8013.77, 8251.59, 8229.34, 9633.75, 11707.19, 13470.83, ],
# [ '8034-2', 3826.36, 6675.61, 7714.20, 8018.86, 8296.44, 10102.85, 12702.67, 14422.67, ],
# [ '1935', 3227.57, 22180.59, 85067.76, 190836.73, 196126.49, 192428.53, 189550.47, 181107.65, ],
# [ '1935', 1131.50, 6422.16, 16155.35, 17549.50, 20035.91, 20107.17, 20101.29, 19579.89, ],
# [ '1935', 2820.54, 18442.43, 76465.60, 183629.93, 175084.21, 185534.00, 185057.53, 180254.30, ],
# [ '1935', 2065.45, 12033.46, 36511.51, 34644.91, 31197.95, 31508.24, 33649.08, 33556.62, ],

import sys

if len(sys.argv) < 3:
    print(f"Usage: python {sys.argv[0]} <data_file> <nth_line>")
    sys.exit(1)

data_file = sys.argv[1]
nth_line = int(sys.argv[2])

def parse_line(line):
    # Remove leading and trailing spaces and the trailing comma
    values = line.strip().strip(', []')
    if not values:
        return False
    # Split the line by comma and convert numeric values to floats
    values = [val.strip() for val in values.split(',')]
    values = [values[0]] + [float(val.strip()) for val in values[1:]]
    return values

# Read data from the file
data = []
with open(data_file, "r") as file:
    for line in file:
        values=parse_line(line)
        if values:
            print(values)
            data.append(values)

# Iterate through the data and compare each line with the line n+nth_line
for i in range(len(data) - nth_line):
    line1 = data[i]
    line2 = data[i + nth_line]

    print(f"{line1[0]} vs {line2[0]}, ", end='')
    for j in range(1, len(line1)):
        res=0
        if line2[j] != 0:
            res=line1[j]/line2[j]*100
        print(f"{res:.2f}, ", end='')
    print()
