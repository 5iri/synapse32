#!/usr/bin/env python3
"""
RISC-V CPU Formal Verification Suite Runner
Runs comprehensive verification tests with parallel execution and reporting.
"""

import os
import sys
import time
import subprocess
import multiprocessing
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from typing import List, Dict, Optional, Tuple
import json
import argparse

@dataclass
class TestResult:
    """Data class to store test results."""
    test_name: str
    category: str
    status: str  # "PASS", "FAIL", "TIMEOUT", "ERROR"
    duration: float
    log_file: Optional[str] = None
    error_message: Optional[str] = None

class VerificationSuiteRunner:
    """Main class for running the verification suite."""

    def __init__(self, max_workers: int = None, timeout: int = 300):
        self.max_workers = max_workers or min(multiprocessing.cpu_count(), 8)
        self.timeout = timeout
        self.results: List[TestResult] = []
        self.start_time = None

    def find_test_files(self, test_dir: Path) -> List[Path]:
        """Find all .sby test files in a directory."""
        if not test_dir.exists():
            return []
        return list(test_dir.glob("*.sby"))

    def run_single_test(self, test_file: Path, category: str) -> TestResult:
        """Run a single SBY test and return the result."""
        test_name = test_file.stem
        start_time = time.time()

        try:
            # Create command
            cmd = ["sby", "-f", str(test_file)]

            # Run the test with timeout
            process = subprocess.run(
                cmd,
                cwd=test_file.parent,
                capture_output=True,
                text=True,
                timeout=self.timeout
            )

            duration = time.time() - start_time

            # Determine status based on return code
            if process.returncode == 0:
                status = "PASS"
                error_message = None
            else:
                status = "FAIL"
                error_message = process.stderr or process.stdout

            # Find log file if it exists
            log_dir = test_file.parent / test_name
            log_file = None
            if log_dir.exists():
                log_files = list(log_dir.glob("**/*.log"))
                if log_files:
                    log_file = str(log_files[0])

            return TestResult(
                test_name=test_name,
                category=category,
                status=status,
                duration=duration,
                log_file=log_file,
                error_message=error_message
            )

        except subprocess.TimeoutExpired:
            duration = time.time() - start_time
            return TestResult(
                test_name=test_name,
                category=category,
                status="TIMEOUT",
                duration=duration,
                error_message=f"Test timed out after {self.timeout} seconds"
            )

        except Exception as e:
            duration = time.time() - start_time
            return TestResult(
                test_name=test_name,
                category=category,
                status="ERROR",
                duration=duration,
                error_message=str(e)
            )

    def run_tests_parallel(self, test_files: List[Tuple[Path, str]]) -> List[TestResult]:
        """Run tests in parallel using ThreadPoolExecutor."""
        results = []

        with ThreadPoolExecutor(max_workers=self.max_workers) as executor:
            # Submit all tests
            future_to_test = {
                executor.submit(self.run_single_test, test_file, category): (test_file.name, category)
                for test_file, category in test_files
            }

            # Collect results as they complete
            for future in as_completed(future_to_test):
                test_name, category = future_to_test[future]
                try:
                    result = future.result()
                    results.append(result)

                    # Print progress
                    status_symbol = {
                        "PASS": "[PASS]",
                        "FAIL": "[FAIL]",
                        "TIMEOUT": "[TIMEOUT]",
                        "ERROR": "[ERROR]"
                    }.get(result.status, "[UNKNOWN]")

                    print(f"{status_symbol} [{category:12}] {result.test_name:20} - {result.status:8} ({result.duration:.2f}s)")

                except Exception as e:
                    print(f"[ERROR] [{category:12}] {test_name:20} - Exception: {e}")

        return results

    def generate_summary_report(self) -> str:
        """Generate a comprehensive summary report."""
        if not self.results:
            return "No test results available."

        # Count results by category and status
        category_stats = {}
        status_counts = {"PASS": 0, "FAIL": 0, "TIMEOUT": 0, "ERROR": 0}

        for result in self.results:
            # Update overall status counts
            status_counts[result.status] += 1

            # Update category stats
            if result.category not in category_stats:
                category_stats[result.category] = {"PASS": 0, "FAIL": 0, "TIMEOUT": 0, "ERROR": 0}
            category_stats[result.category][result.status] += 1

        # Calculate durations
        total_duration = sum(r.duration for r in self.results)
        wall_time = time.time() - self.start_time if self.start_time else 0

        # Build report
        report = []
        report.append("RISC-V CPU Formal Verification Summary Report")
        report.append("=" * 60)
        report.append(f"Total Tests: {len(self.results)}")
        report.append(f"Wall Time: {wall_time:.2f} seconds")
        report.append(f"CPU Time: {total_duration:.2f} seconds")
        report.append(f"Speedup: {total_duration/wall_time:.2f}x" if wall_time > 0 else "Speedup: N/A")
        report.append("")

        # Overall status summary
        report.append("Overall Results:")
        for status, count in status_counts.items():
            percentage = (count / len(self.results)) * 100
            symbol = {"PASS": "[PASS]", "FAIL": "[FAIL]", "TIMEOUT": "[TIMEOUT]", "ERROR": "[ERROR]"}[status]
            report.append(f"  {symbol} {status:8}: {count:3} tests ({percentage:5.1f}%)")
        report.append("")

        # Category breakdown
        report.append("Results by Category:")
        for category, stats in category_stats.items():
            total_cat = sum(stats.values())
            pass_rate = (stats["PASS"] / total_cat) * 100 if total_cat > 0 else 0
            report.append(f"  {category:15}: {stats['PASS']:2}/{total_cat:2} passed ({pass_rate:5.1f}%)")
        report.append("")

        # Failed tests details
        failed_tests = [r for r in self.results if r.status != "PASS"]
        if failed_tests:
            report.append("Failed Tests:")
            for result in failed_tests:
                report.append(f"  [{result.category:12}] {result.test_name:20} - {result.status}")
                if result.error_message:
                    # Truncate long error messages
                    error = result.error_message[:100] + "..." if len(result.error_message) > 100 else result.error_message
                    report.append(f"    Error: {error}")
            report.append("")

        # Performance stats
        fastest = min(self.results, key=lambda r: r.duration)
        slowest = max(self.results, key=lambda r: r.duration)
        avg_duration = total_duration / len(self.results)

        report.append("Performance Statistics:")
        report.append(f"  Fastest: {fastest.test_name:20} ({fastest.duration:.2f}s)")
        report.append(f"  Slowest: {slowest.test_name:20} ({slowest.duration:.2f}s)")
        report.append(f"  Average: {avg_duration:.2f}s per test")

        return "\n".join(report)

    def save_detailed_report(self, output_file: Path):
        """Save detailed test results to JSON file."""
        report_data = {
            "summary": {
                "total_tests": len(self.results),
                "wall_time": time.time() - self.start_time if self.start_time else 0,
                "cpu_time": sum(r.duration for r in self.results),
                "timestamp": time.strftime("%Y-%m-%d %H:%M:%S")
            },
            "results": [
                {
                    "test_name": r.test_name,
                    "category": r.category,
                    "status": r.status,
                    "duration": r.duration,
                    "log_file": r.log_file,
                    "error_message": r.error_message
                }
                for r in self.results
            ]
        }

        with open(output_file, 'w') as f:
            json.dump(report_data, f, indent=2)

    def run_verification_suite(self, formal_dir: Path, categories: List[str] = None) -> bool:
        """Run the complete verification suite."""
        self.start_time = time.time()

        print("Starting RISC-V CPU Formal Verification Suite")
        print("=" * 60)
        print(f"Working directory: {formal_dir}")
        print(f"Max parallel workers: {self.max_workers}")
        print(f"Timeout per test: {self.timeout}s")
        print("")

        # Define test categories and their directories
        test_categories = {
            "instructions": "instructions",
            "system": "system_checks",
            "integration": "integration"
        }

        # Filter categories if specified
        if categories:
            test_categories = {k: v for k, v in test_categories.items() if k in categories}

        # Collect all test files
        all_test_files = []
        for category, subdir in test_categories.items():
            test_dir = formal_dir / subdir
            test_files = self.find_test_files(test_dir)
            all_test_files.extend([(f, category) for f in test_files])

        if not all_test_files:
            print("[ERROR] No test files found!")
            return False

        print(f"Found {len(all_test_files)} test files across {len(test_categories)} categories")
        for category, subdir in test_categories.items():
            test_dir = formal_dir / subdir
            count = len(self.find_test_files(test_dir))
            print(f"  {category:12}: {count:3} tests")
        print("")

        # Run tests
        print("Running verification tests...")
        print("-" * 60)
        self.results = self.run_tests_parallel(all_test_files)

        # Generate and display summary
        print("\n" + "=" * 60)
        summary = self.generate_summary_report()
        print(summary)

        # Save detailed report
        report_file = formal_dir / "verification_report.json"
        self.save_detailed_report(report_file)
        print(f"\nDetailed report saved to: {report_file}")

        # Return success if all tests passed
        passed_tests = len([r for r in self.results if r.status == "PASS"])
        return passed_tests == len(self.results)

def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(description="Run RISC-V CPU formal verification suite")
    parser.add_argument("--formal-dir", type=Path, default=Path(__file__).parent,
                        help="Path to formal verification directory")
    parser.add_argument("--categories", nargs="+", choices=["instructions", "system", "integration"],
                        help="Categories to test (default: all)")
    parser.add_argument("--workers", type=int,
                        help="Number of parallel workers")
    parser.add_argument("--timeout", type=int, default=300,
                        help="Timeout per test in seconds")
    parser.add_argument("--generate-only", action="store_true",
                        help="Only generate test configs, don't run tests")

    args = parser.parse_args()

    # Change to formal directory
    formal_dir = args.formal_dir.resolve()
    if not formal_dir.exists():
        print(f"[ERROR] Formal directory not found: {formal_dir}")
        return 1

    # Generate test configurations first
    if not (formal_dir / "instructions").exists() or args.generate_only:
        print("Generating test configurations...")
        try:
            # Import and run the test generation script
            sys.path.insert(0, str(formal_dir))
            from generate_instruction_tests import main as generate_tests
            generate_tests()
            print("[PASS] Test configurations generated successfully")

            if args.generate_only:
                return 0
        except ImportError:
            print("[ERROR] Could not import test generation script")
            return 1
        except Exception as e:
            print(f"[ERROR] Error generating tests: {e}")
            return 1

    # Run verification suite
    runner = VerificationSuiteRunner(
        max_workers=args.workers,
        timeout=args.timeout
    )

    success = runner.run_verification_suite(formal_dir, args.categories)

    return 0 if success else 1

if __name__ == "__main__":
    sys.exit(main())
