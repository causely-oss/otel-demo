#!/usr/bin/env python

"""
Feature Flag Toggle Script for flagd-ui
Usage: python toggle-flags.py <flag_name> <variant>
Example: python toggle-flags.py adFailure on
"""

import sys
import json
import requests
import argparse
from typing import Dict, Any, Optional


# Default Base URL for the flagd-ui API
DEFAULT_BASE_URL = "http://localhost:8080/feature/api"
BASE_URL = DEFAULT_BASE_URL  # Will be updated by argument parsing


def show_usage():
    """Display usage information"""
    print("Usage: python toggle-flags.py <flag_name> <variant> [--base-url URL]")
    print("")
    print("Available flags and variants:")
    print("  productCatalogFailure: on, off")
    print("  recommendationCacheFailure: on, off")
    print("  adManualGc: on, off")
    print("  adHighCpu: on, off")
    print("  adFailure: on, off")
    print("  kafkaQueueProblems: on, off")
    print("  cartFailure: on, off")
    print("  paymentFailure: 100%, 90%, 75%, 50%, 25%, 10%, off")
    print("  paymentUnreachable: on, off")
    print("  loadGeneratorFloodHomepage: on, off")
    print("  imageSlowLoad: 10sec, 5sec, off")
    print("")
    print("Options:")
    print(f"  --base-url URL    Base URL for flagd-ui API (default: {DEFAULT_BASE_URL})")
    print("")
    print("Examples:")
    print("  python toggle-flags.py adFailure on")
    print("  python toggle-flags.py paymentFailure 50%")
    print("  python toggle-flags.py imageSlowLoad 5sec")
    print("  python toggle-flags.py list  # Show current status")
    print("  python toggle-flags.py adFailure on --base-url http://custom-host:9090/feature/api")


def get_variant_value(flag_name: str, variant: str) -> Optional[Any]:
    """Get the variant value based on flag and variant name"""
    boolean_flags = [
        "productCatalogFailure", "recommendationCacheFailure", "adManualGc",
        "adHighCpu", "adFailure", "cartFailure", "paymentUnreachable"
    ]
    
    numeric_flags = ["kafkaQueueProblems", "loadGeneratorFloodHomepage"]
    
    if flag_name in boolean_flags:
        if variant == "on":
            return True
        elif variant == "off":
            return False
        else:
            return None
    
    elif flag_name in numeric_flags:
        if variant == "on":
            return 100
        elif variant == "off":
            return 0
        else:
            return None
    
    elif flag_name == "paymentFailure":
        variant_map = {
            "100%": 1,
            "90%": 0.95,
            "75%": 0.75,
            "50%": 0.5,
            "25%": 0.25,
            "10%": 0.1,
            "off": 0
        }
        return variant_map.get(variant)
    
    elif flag_name == "imageSlowLoad":
        variant_map = {
            "10sec": 10000,
            "5sec": 5000,
            "off": 0
        }
        return variant_map.get(variant)
    
    return None


def get_all_variants(flag_name: str) -> Dict[str, Any]:
    """Get all flag variants for JSON construction"""
    boolean_flags = [
        "productCatalogFailure", "recommendationCacheFailure", "adManualGc",
        "adHighCpu", "adFailure", "cartFailure", "paymentUnreachable"
    ]
    
    numeric_flags = ["kafkaQueueProblems", "loadGeneratorFloodHomepage"]
    
    if flag_name in boolean_flags:
        return {"on": True, "off": False}
    elif flag_name in numeric_flags:
        return {"on": 100, "off": 0}
    elif flag_name == "paymentFailure":
        return {
            "100%": 1,
            "90%": 0.95,
            "75%": 0.75,
            "50%": 0.5,
            "25%": 0.25,
            "10%": 0.1,
            "off": 0
        }
    elif flag_name == "imageSlowLoad":
        return {"10sec": 10000, "5sec": 5000, "off": 0}
    
    return {}


def get_flag_description(flag_name: str) -> str:
    """Get flag description"""
    descriptions = {
        "productCatalogFailure": "Fail product catalog service on a specific product",
        "recommendationCacheFailure": "Fail recommendation service cache",
        "adManualGc": "Triggers full manual garbage collections in the ad service",
        "adHighCpu": "Triggers high cpu load in the ad service",
        "adFailure": "Fail ad service",
        "kafkaQueueProblems": "Overloads Kafka queue while simultaneously introducing a consumer side delay leading to a lag spike",
        "cartFailure": "Fail cart service",
        "paymentFailure": "Fail payment service charge requests n%",
        "paymentUnreachable": "Payment service is unavailable",
        "loadGeneratorFloodHomepage": "Flood the frontend with a large amount of requests.",
        "imageSlowLoad": "slow loading images in the frontend"
    }
    return descriptions.get(flag_name, "")


def construct_json(target_flag: str, target_variant: str) -> Dict[str, Any]:
    """Construct the complete JSON payload"""
    all_flags = [
        "productCatalogFailure", "recommendationCacheFailure", "adManualGc",
        "adHighCpu", "adFailure", "kafkaQueueProblems", "cartFailure",
        "paymentFailure", "paymentUnreachable", "loadGeneratorFloodHomepage",
        "imageSlowLoad"
    ]
    
    flags = {}
    
    for flag_name in all_flags:
        # Set default variant based on target flag
        if flag_name == target_flag:
            default_variant = target_variant
        else:
            # Set sensible defaults for other flags
            if flag_name == "productCatalogFailure":
                default_variant = "on"
            else:
                default_variant = "off"
        
        flags[flag_name] = {
            "description": get_flag_description(flag_name),
            "state": "ENABLED",
            "variants": get_all_variants(flag_name),
            "defaultVariant": default_variant
        }
    
    return {
        "data": {
            "$schema": "https://flagd.dev/schema/v0/flags.json",
            "flags": flags
        }
    }


def list_current_status():
    """List current flag status"""
    try:
        print("Fetching current flag status...")
        response = requests.get(f"{BASE_URL}/read-file", 
                              headers={'Content-Type': 'application/json'},
                              timeout=10)
        
        if response.status_code == 200:
            data = response.json()
            if 'flags' in data:
                for flag_name, flag_data in data['flags'].items():
                    default_variant = flag_data.get('defaultVariant', 'unknown')
                    description = flag_data.get('description', '')
                    print(f"{flag_name}: {default_variant} ({description})")
            else:
                print("No flags found in response")
        else:
            print(f"Error: HTTP {response.status_code}")
            print(f"Ensure flagd-ui is running and accessible at {BASE_URL}")
    
    except requests.exceptions.RequestException as e:
        print(f"Error connecting to flagd-ui: {e}")
        print(f"Ensure flagd-ui is running and accessible at {BASE_URL}")
    except Exception as e:
        print(f"Error: {e}")


def set_flag(flag_name: str, variant: str) -> bool:
    """Set a flag to a specific variant"""
    # Validate flag name and variant
    variant_value = get_variant_value(flag_name, variant)
    if variant_value is None:
        print(f"Error: Invalid flag name '{flag_name}' or variant '{variant}'")
        show_usage()
        return False
    
    print(f"Setting {flag_name} to {variant}...")
    
    try:
        # Construct JSON payload
        json_payload = construct_json(flag_name, variant)
        
        # Make the API call
        response = requests.post(f"{BASE_URL}/write-to-file",
                               json=json_payload,
                               headers={'Content-Type': 'application/json'},
                               timeout=10)
        
        if response.status_code in [200, 201]:
            print(f"✅ Successfully set {flag_name} to {variant}")
            return True
        else:
            print(f"❌ Failed to set flag. HTTP Code: {response.status_code}")
            print(f"Response: {response.text}")
            return False
    
    except requests.exceptions.RequestException as e:
        print(f"❌ Failed to connect to flagd-ui: {e}")
        print(f"Ensure flagd-ui is running and accessible at {BASE_URL}")
        return False
    except Exception as e:
        print(f"❌ Error: {e}")
        return False


def main():
    """Main script logic"""
    global BASE_URL
    
    parser = argparse.ArgumentParser(
        description="Feature Flag Toggle Script for flagd-ui",
        add_help=False  # We'll handle help ourselves
    )
    
    parser.add_argument("flag_name", nargs="?", help="Flag name to toggle")
    parser.add_argument("variant", nargs="?", help="Variant to set (on/off/percentage/etc)")
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL, 
                       help=f"Base URL for flagd-ui API (default: {DEFAULT_BASE_URL})")
    parser.add_argument("-h", "--help", action="store_true", help="Show help message")
    
    try:
        args = parser.parse_args()
    except SystemExit:
        show_usage()
        sys.exit(1)
    
    # Update global BASE_URL from argument
    BASE_URL = args.base_url
    
    # Handle help
    if args.help or not args.flag_name:
        show_usage()
        sys.exit(0)
    
    # Handle list command
    if args.flag_name == "list":
        list_current_status()
        sys.exit(0)
    
    # Validate we have both flag_name and variant
    if not args.variant:
        print("Error: Both flag_name and variant are required")
        show_usage()
        sys.exit(1)
    
    success = set_flag(args.flag_name, args.variant)
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main() 