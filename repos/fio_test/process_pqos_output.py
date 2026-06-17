import matplotlib.pyplot as plt
import re
import sys
import os

def main(input_file, output_folder):
    # Initialize data storage
    relative_times = []
    llc_usage_data = {}
    llc_misses_data = {}
    ipc_data = {}
    mbl_data = {}
    mbr_data = {}

    # Read the log file
    with open(input_file, 'r') as file:
        lines = file.readlines()

    # Parse the log file
    time_counter = 0
    for line in lines:
        time_match = re.match(r'TIME (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})', line)
        if time_match:
            relative_times.append(time_counter)
            time_counter += 1
        else:
            core_match = re.match(r'\s*(\d+)\s+(\d+\.\d+)\s+(\d+)k?\s+(\d+\.\d+)\s+(\d+\.\d+)\s+(\d+\.\d+)', line)
            if core_match:
                core_id = int(core_match.group(1))
                ipc = float(core_match.group(2))
                llc_misses = int(core_match.group(3))
                llc_usage = float(core_match.group(4))
                mbl = float(core_match.group(5))
                mbr = float(core_match.group(6))

                if core_id not in llc_usage_data:
                    llc_usage_data[core_id] = []
                if core_id not in llc_misses_data:
                    llc_misses_data[core_id] = []
                if core_id not in ipc_data:
                    ipc_data[core_id] = []
                if core_id not in mbl_data:
                    mbl_data[core_id] = []
                if core_id not in mbr_data:
                    mbr_data[core_id] = []

                llc_usage_data[core_id].append(llc_usage)
                llc_misses_data[core_id].append(llc_misses)
                ipc_data[core_id].append(ipc)
                mbl_data[core_id].append(mbl)
                mbr_data[core_id].append(mbr)

    # Ensure the output folder exists
    os.makedirs(output_folder, exist_ok=True)

    # Plot LLC Usage
    plt.figure(figsize=(10, 6))
    for core_id, llc_usages in llc_usage_data.items():
        plt.plot(relative_times, llc_usages, label=f'Core {core_id}')
    plt.xlabel('Time (seconds)')
    plt.ylabel('LLC Usage (KB)')
    plt.title('LLC Usage Over Time')
    plt.legend()
    plt.tight_layout()
    plt.grid(True)
    plt.savefig(os.path.join(output_folder, 'llc_usage.svg'), format='svg')
    plt.close()

    # Plot LLC Misses
    plt.figure(figsize=(10, 6))
    for core_id, llc_misses in llc_misses_data.items():
        plt.plot(relative_times, llc_misses, label=f'Core {core_id}')
    plt.xlabel('Time (seconds)')
    plt.ylabel('LLC Misses')
    plt.title('LLC Misses Over Time')
    plt.legend()
    plt.tight_layout()
    plt.grid(True)
    plt.savefig(os.path.join(output_folder, 'llc_misses.svg'), format='svg')
    plt.close()

    # Plot IPC
    plt.figure(figsize=(10, 6))
    for core_id, ipcs in ipc_data.items():
        plt.plot(relative_times, ipcs, label=f'Core {core_id}')
    plt.xlabel('Time (seconds)')
    plt.ylabel('IPC')
    plt.title('IPC Over Time')
    plt.legend()
    plt.tight_layout()
    plt.grid(True)
    plt.savefig(os.path.join(output_folder, 'ipc.svg'), format='svg')
    plt.close()

    # Plot MBL
    plt.figure(figsize=(10, 6))
    for core_id, mbls in mbl_data.items():
        plt.plot(relative_times, mbls, label=f'Core {core_id}')
    plt.xlabel('Time (seconds)')
    plt.ylabel('MBL (MB/s)')
    plt.title('Memory Bandwidth Load (MBL) Over Time')
    plt.legend()
    plt.tight_layout()
    plt.grid(True)
    plt.savefig(os.path.join(output_folder, 'mbl.svg'), format='svg')
    plt.close()

    # Plot MBR
    plt.figure(figsize=(10, 6))
    for core_id, mbrs in mbr_data.items():
        plt.plot(relative_times, mbrs, label=f'Core {core_id}')
    plt.xlabel('Time (seconds)')
    plt.ylabel('MBR (MB/s)')
    plt.title('Memory Bandwidth Read (MBR) Over Time')
    plt.legend()
    plt.tight_layout()
    plt.grid(True)
    plt.savefig(os.path.join(output_folder, 'mbr.svg'), format='svg')
    plt.close()

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python run.py <input_log_file> <output_folder>")
        sys.exit(1)

    input_file = sys.argv[1]
    output_folder = sys.argv[2]
    main(input_file, output_folder)
