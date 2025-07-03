#!/usr/bin/env python

"""
Chaos Scheduler Script for flagd-ui
Continuously triggers random feature flags at specified intervals
Usage: python chaos-scheduler.py <interval> [--dry-run] [--seed <number>]
Example: python chaos-scheduler.py 15min --dry-run --seed 42
"""

import sys
import time
import random
import subprocess
import argparse
import re
from datetime import datetime
from pathlib import Path
from typing import Tuple


class ChaosScheduler:
    def __init__(self):
        self.dry_run = False
        self.interval_seconds = 0
        self.seed = None
        self.toggle_script = "./toggle-flags.py"
        self.base_url = "http://localhost:8080/feature/api"  # Default base URL
        
        # Available flags that can be turned "on" (non-off variants)
        self.available_flags = {
            "productCatalogFailure": ["on"],
            "recommendationCacheFailure": ["on"],
            "adManualGc": ["on"],
            "adHighCpu": ["on"],
            "adFailure": ["on"],
            "kafkaQueueProblems": ["on"],
            "cartFailure": ["on"],
            "paymentFailure": ["100%", "90%", "75%", "50%", "25%", "10%"],
            "paymentUnreachable": ["on"],
            "loadGeneratorFloodHomepage": ["on"],
            "imageSlowLoad": ["10sec", "5sec"]
        }
    
    def show_usage(self):
        """Display usage information"""
        print("Usage: python chaos-scheduler.py <interval> [--dry-run] [--seed <number>] [--base-url URL]")
        print("")
        print("Interval formats:")
        print("  30sec, 1min, 15min, 1h, 2h, 1day")
        print("  Examples: 30sec, 5min, 1h, 2day")
        print("")
        print("Options:")
        print("  --dry-run         Only print what would be done, don't make actual API calls")
        print("  --seed <number>   Use specific seed for reproducible random patterns")
        print("  --base-url URL    Base URL for flagd-ui API (default: http://localhost:8080/feature/api)")
        print("")
        print("Examples:")
        print("  python chaos-scheduler.py 15min")
        print("  python chaos-scheduler.py 1h --dry-run")
        print("  python chaos-scheduler.py 30sec --seed 12345")
        print("  python chaos-scheduler.py 5min --dry-run --seed 42")
        print("  python chaos-scheduler.py 15min --base-url http://remote-server:9090/feature/api")
        print("")
        print("Reproducibility:")
        print("  Using the same seed will produce identical chaos patterns across runs.")
        print("  The seed will be logged at startup for easy reproduction.")
        print("")
        print("Note: Requires toggle-flags.py to be in the same directory")
    
    def parse_interval(self, interval_str: str) -> int:
        """Parse time interval string to seconds"""
        match = re.match(r'(\d+)([a-zA-Z]+)', interval_str)
        if not match:
            return 0
        
        number = int(match.group(1))
        unit = match.group(2).lower()
        
        unit_multipliers = {
            'sec': 1, 'second': 1, 'seconds': 1,
            'min': 60, 'minute': 60, 'minutes': 60,
            'h': 3600, 'hour': 3600, 'hours': 3600,
            'day': 86400, 'days': 86400
        }
        
        multiplier = unit_multipliers.get(unit)
        if multiplier is None:
            return 0
        
        return number * multiplier
    
    def log_message(self, message: str):
        """Log message with timestamp"""
        timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        print(f"[{timestamp}] {message}")
    
    def format_duration(self, seconds: int) -> str:
        """Format duration for display"""
        if seconds < 60:
            return f"{seconds}s"
        elif seconds < 3600:
            minutes = seconds // 60
            remaining_seconds = seconds % 60
            return f"{minutes}m {remaining_seconds}s"
        elif seconds < 86400:
            hours = seconds // 3600
            remaining_minutes = (seconds % 3600) // 60
            return f"{hours}h {remaining_minutes}m"
        else:
            days = seconds // 86400
            remaining_hours = (seconds % 86400) // 3600
            return f"{days}d {remaining_hours}h"
    
    def get_random_flag_variant(self) -> Tuple[str, str]:
        """Get random flag and non-off variant"""
        flag_name = random.choice(list(self.available_flags.keys()))
        variant = random.choice(self.available_flags[flag_name])
        return flag_name, variant
    
    def set_flag(self, flag_name: str, variant: str) -> bool:
        """Set flag using toggle-flags.py"""
        # Build command with base_url if not default
        cmd = [sys.executable, self.toggle_script, flag_name, variant]
        if self.base_url != "http://localhost:8080/feature/api":
            cmd.extend(["--base-url", self.base_url])
        
        if self.dry_run:
            cmd_str = " ".join(cmd)
            self.log_message(f"🧪 [DRY-RUN] Would run: {cmd_str}")
            return True
        
        try:
            # Use the existing toggle-flags.py script
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            
            if result.returncode == 0:
                return True
            else:
                self.log_message(f"❌ Failed to set {flag_name} to {variant} using {self.toggle_script}")
                if result.stderr:
                    self.log_message(f"Error: {result.stderr.strip()}")
                return False
        
        except subprocess.TimeoutExpired:
            self.log_message(f"❌ Timeout setting {flag_name} to {variant}")
            return False
        except Exception as e:
            self.log_message(f"❌ Error setting {flag_name} to {variant}: {e}")
            return False
    
    def chaos_loop(self):
        """Main chaos loop"""
        interval_count = 0
        
        self.log_message(f"🚀 Starting Chaos Scheduler with interval: {self.format_duration(self.interval_seconds)}")
        
        if self.dry_run:
            self.log_message("🧪 Running in DRY-RUN mode - no actual changes will be made")
        
        if self.seed is not None:
            self.log_message(f"🎲 Using seed: {self.seed} (for reproducible patterns)")
        else:
            current_seed = random.randrange(2**31)
            random.seed(current_seed)
            self.log_message(f"🎲 Using random seed: {current_seed} (use --seed {current_seed} to reproduce this run)")
        
        try:
            while True:
                interval_count += 1
                interval_start_time = time.time()
                interval_end_time = interval_start_time + self.interval_seconds
                
                self.log_message(f"📅 Beginning interval #{interval_count} (duration: {self.format_duration(self.interval_seconds)})")
                
                # Calculate random trigger time within this interval (0 to interval_seconds)
                random_offset = random.randint(0, max(0, self.interval_seconds - 1))
                trigger_time = interval_start_time + random_offset
                
                trigger_time_str = datetime.fromtimestamp(trigger_time).strftime('%H:%M:%S')
                self.log_message(f"⏰ Next trigger scheduled in {self.format_duration(random_offset)} (at {trigger_time_str})")
                
                # Wait until trigger time
                current_time = time.time()
                if current_time < trigger_time:
                    time.sleep(trigger_time - current_time)
                
                # Get random flag and variant
                flag_name, variant = self.get_random_flag_variant()
                
                # Calculate remaining time in interval for maximum duration
                current_time = time.time()
                remaining_time = int(interval_end_time - current_time)
                
                if remaining_time <= 0:
                    self.log_message("⚠️  Interval ended before flag could be triggered, moving to next interval")
                    continue
                
                # Random duration flag stays on (1 second to remaining time)
                flag_duration = random.randint(1, max(1, remaining_time))
                
                self.log_message(f"🎯 TRIGGER: Setting {flag_name} to {variant} for {self.format_duration(flag_duration)}")
                
                # Set flag to active state
                if self.set_flag(flag_name, variant):
                    if not self.dry_run:
                        self.log_message(f"✅ Successfully activated {flag_name} = {variant}")
                    
                    # Wait for the flag duration
                    time.sleep(flag_duration)
                    
                    # Set flag back to off
                    self.log_message(f"🔄 REVERT: Setting {flag_name} back to off")
                    if self.set_flag(flag_name, "off"):
                        if not self.dry_run:
                            self.log_message(f"✅ Successfully reverted {flag_name} to off")
                
                # Wait until end of interval
                current_time = time.time()
                if current_time < interval_end_time:
                    wait_time = int(interval_end_time - current_time)
                    if wait_time > 0:
                        self.log_message(f"⏸️  Waiting {self.format_duration(wait_time)} until end of interval")
                        time.sleep(wait_time)
                
                self.log_message(f"🏁 End of interval #{interval_count}")
                print("----------------------------------------")
                
        except KeyboardInterrupt:
            self.log_message("🛑 Received shutdown signal, exiting gracefully...")
            sys.exit(0)
    
    def validate_toggle_script(self):
        """Check if toggle-flags.py exists and is executable"""
        script_path = Path(self.toggle_script)
        
        if not script_path.exists():
            print(f"Error: {self.toggle_script} not found in current directory")
            print("Please ensure toggle-flags.py is in the same directory as this script")
            sys.exit(1)
        
        # Test if the script is runnable
        try:
            cmd = [sys.executable, self.toggle_script, "--help"]
            if self.base_url != "http://localhost:8080/feature/api":
                cmd.extend(["--base-url", self.base_url])
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
            
            if result.returncode != 0:
                print(f"Error: {self.toggle_script} is not working properly")
                print("Please ensure toggle-flags.py is functional")
                sys.exit(1)
                
        except Exception as e:
            print(f"Error: Cannot execute {self.toggle_script}: {e}")
            sys.exit(1)
    
    def parse_args(self):
        """Parse command line arguments"""
        if len(sys.argv) == 1 or sys.argv[1] in ["-h", "--help"]:
            self.show_usage()
            sys.exit(0)
        
        parser = argparse.ArgumentParser(description="Chaos Scheduler for flagd-ui", add_help=False)
        parser.add_argument("interval", help="Time interval (e.g., 15min, 1h, 30sec)")
        parser.add_argument("--dry-run", "-n", action="store_true", help="Only print what would be done")
        parser.add_argument("--seed", type=int, help="Seed for reproducible random patterns")
        parser.add_argument("--base-url", default="http://localhost:8080/feature/api", 
                           help="Base URL for flagd-ui API (default: http://localhost:8080/feature/api)")
        
        try:
            args = parser.parse_args()
        except SystemExit:
            self.show_usage()
            sys.exit(1)
        
        # Parse interval
        self.interval_seconds = self.parse_interval(args.interval)
        if self.interval_seconds == 0:
            print(f"Error: Invalid interval format '{args.interval}'")
            self.show_usage()
            sys.exit(1)
        
        # Validate minimum interval (10 seconds)
        if self.interval_seconds < 10:
            print("Error: Interval must be at least 10 seconds")
            sys.exit(1)
        
        # Set other options
        self.dry_run = args.dry_run
        self.base_url = args.base_url
        
        if args.seed is not None:
            self.seed = args.seed
            random.seed(self.seed)
    
    def run(self):
        """Main entry point"""
        self.parse_args()
        self.validate_toggle_script()
        self.chaos_loop()


def main():
    """Main function"""
    scheduler = ChaosScheduler()
    scheduler.run()


if __name__ == "__main__":
    main() 