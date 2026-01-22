#!/usr/bin/env python3
"""
Test script to invoke the Master Agent.

Usage:
    python test.py                          # Interactive mode
    python test.py "summarize files: a.pdf" # Single message mode
    python test.py --examples               # Run example tests
"""

import asyncio
import sys
import os

# Add the current directory to path for imports
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# Load environment variables from .env file
from dotenv import load_dotenv
load_dotenv()

from agent_manager import AgentManager, on_intermediate_message
from semantic_kernel.contents import FunctionCallContent, FunctionResultContent
from semantic_kernel.contents.chat_message_content import ChatMessageContent, TextContent


async def print_intermediate_message(agent_response: ChatMessageContent):
    """Print intermediate messages from the agent during streaming."""
    for item in agent_response.items or []:
        if isinstance(item, FunctionResultContent):
            result_preview = str(item.result)[:200] + "..." if len(str(item.result)) > 200 else str(item.result)
            print(f"  📋 Function Result ({item.name}): {result_preview}")
        elif isinstance(item, FunctionCallContent):
            print(f"  🔧 Calling: {item.name}")
            if item.arguments:
                print(f"     Args: {item.arguments}")
        elif isinstance(item, TextContent):
            if item.text:
                text_preview = item.text[:100] + "..." if len(item.text) > 100 else item.text
                print(f"  💬 {text_preview}")


async def test_single_message(message: str) -> None:
    """Test the agent with a single message."""
    print(f"\n{'='*60}")
    print("Master Agent Test (Semantic Kernel + Azure AI Foundry)")
    print(f"{'='*60}\n")
    
    manager = AgentManager()
    
    try:
        print("Initializing Agent Manager...")
        await manager.initialize()
        print("✅ Agent Manager initialized\n")
        
        print(f"📤 User: {message}\n")
        print("Processing... (streaming with intermediate messages)\n")
        
        # Use streaming invoke with intermediate message callback
        result = await manager.invoke_master_agent(
            message, 
            on_intermediate=print_intermediate_message
        )
        
        print(f"\n📥 Agent ({result.agent_used}):\n")
        print(result.response)
        print()
        
        if result.plugins_invoked:
            print(f"🔧 Tools invoked: {', '.join(result.plugins_invoked)}")
        
    finally:
        print("\nCleaning up...")
        await manager.cleanup()
        print("✅ Done")


async def test_interactive() -> None:
    """Interactive test mode."""
    print(f"\n{'='*60}")
    print("Master Agent Interactive Test")
    print(f"{'='*60}")
    print("Type 'quit' or 'exit' to stop")
    print("Type 'info' to see agent information")
    print(f"{'='*60}\n")
    
    manager = AgentManager()
    
    try:
        print("Initializing Agent Manager...")
        await manager.initialize()
        print("✅ Agent Manager initialized\n")
        
        while True:
            try:
                message = input("📤 You: ").strip()
            except EOFError:
                break
            
            if not message:
                continue
            
            if message.lower() in ["quit", "exit", "q"]:
                break
            
            if message.lower() == "info":
                info = manager.get_agents_info()
                print("\n📋 Agent Information:")
                for agent in info["agents"]:
                    print(f"  - {agent['name']}: {agent['status']}")
                    if agent.get('id'):
                        print(f"    ID: {agent['id']}")
                print("\n🔧 Available Tools:")
                for tool in info["tools"]:
                    print(f"  - {tool['name']}: {tool['description']}")
                print()
                continue
            
            print("\nProcessing... (streaming)\n")
            
            # Use streaming invoke with intermediate message callback
            result = await manager.invoke_master_agent(
                message,
                on_intermediate=print_intermediate_message
            )
            
            print(f"\n📥 Master Agent:\n")
            print(result.response)
            print()
            
            if result.plugins_invoked:
                print(f"🔧 Tools invoked: {', '.join(result.plugins_invoked)}\n")
        
    finally:
        print("\nCleaning up...")
        await manager.cleanup()
        print("✅ Done")


async def test_examples() -> None:
    """Run through example test cases."""
    print(f"\n{'='*60}")
    print("Master Agent Example Tests")
    print(f"{'='*60}\n")
    
    manager = AgentManager()
    
    examples = [
        "What can you help me with?",
        "What is the system status?",
        "Summarize these files: report.pdf, data.csv, notes.txt",
    ]
    
    try:
        print("Initializing Agent Manager...")
        await manager.initialize()
        print("✅ Agent Manager initialized\n")
        
        for i, message in enumerate(examples, 1):
            print(f"\n{'─'*60}")
            print(f"Test {i}/{len(examples)}")
            print(f"{'─'*60}")
            print(f"📤 User: {message}\n")
            
            result = await manager.invoke_master_agent(
                message,
                on_intermediate=print_intermediate_message
            )
            
            print(f"\n📥 Agent:\n{result.response}\n")
            
            if result.plugins_invoked:
                print(f"🔧 Tools: {', '.join(result.plugins_invoked)}")
        
        print(f"\n{'='*60}")
        print("All tests completed!")
        print(f"{'='*60}\n")
        
    finally:
        await manager.cleanup()


def main():
    """Main entry point."""
    if len(sys.argv) > 1:
        # Check for special commands
        if sys.argv[1] == "--examples":
            asyncio.run(test_examples())
        else:
            # Single message mode
            message = " ".join(sys.argv[1:])
            asyncio.run(test_single_message(message))
    else:
        # Interactive mode
        asyncio.run(test_interactive())


if __name__ == "__main__":
    main()
