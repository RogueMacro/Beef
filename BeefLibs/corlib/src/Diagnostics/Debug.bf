namespace System.Diagnostics
{
	static class Debug
	{
#if !DEBUG
		[SkipCall]
#endif
		public static void Assert(bool condition, String error = Compiler.CallerExpression[0], String filePath = Compiler.CallerFilePath, int line = Compiler.CallerLineNum) 
		{
			if (!condition)
			{
				if ((!Compiler.IsComptime) && (Runtime.CheckAssertError != null) && (Runtime.CheckAssertError(.Debug, error, filePath, line) == .Ignore))
					return;
#if !BF_RUNTIME_REDUCED
				String failStr = scope .()..Append("Assert failed: ", error, " at line ");
				line.ToString(failStr);
				failStr.Append(" in ", filePath);
				Internal.FatalError(failStr, 1);
#else
				Internal.FatalError(error, 1);
#endif
			}
		}

#if !DEBUG
		[SkipCall]
#endif
		public static void FatalError(StringView msg = "Fatal error encountered", String filePath = Compiler.CallerFilePath, int line = Compiler.CallerLineNum)
		{
			String failStr = scope .()..Append(msg, " at line ");
			line.ToString(failStr);
			failStr.Append(" in ", filePath);
			Internal.FatalError(failStr, 1);
		}

#if !DEBUG
		[SkipCall]
#endif
		public static void AssertNotStack(Object obj)
		{
#if BF_ENABLE_OBJECT_DEBUG_FLAGS
			if ((obj != null) && (obj.[Friend]GetFlags() & 8 != 0))
				Internal.FatalError("Assert failed", 1);
#endif
		}

#if !BF_RUNTIME_DISABLE
		[CallingConvention(.Cdecl)]
		static extern void Write(char8* str, int strLen);
		[CallingConvention(.Cdecl)]
		static extern void Write(int val);
#else
		static void Write(char8* str, int strLen)
		{
		}
		static void Write(int val)
		{
		}
#endif

		public static void Write(String line)
		{
			Write(line.Ptr, line.Length);
		}

		public static void Write(StringView sv)
		{
			Write(sv.[Friend]mPtr, sv.[Friend]mLength);
		}

		public static void Write(StringView fmt, params Span<Object> args)
		{
			String str = scope String(4096);
			str.AppendF(fmt, params args);
			Write(str);
		}

		public static void Write(Object obj)
		{
			String str = scope String(4096);
			obj.ToString(str);
			Write(str);
		}

		public static void WriteLine()
		{
			Write((char8*)"\n", 1);
		}

		public static void WriteLine(StringView line)
		{
			String lineStr = scope String(Math.Min(line.Length + 1, 4096));
			lineStr.Append(line);
			lineStr.Append('\n');
			Write(lineStr.Ptr, lineStr.Length);
		}

		public static void WriteLine(StringView strFormat, params Span<Object> args)
		{
			String paramStr = scope String(4096);
			paramStr.AppendF(strFormat, params args);
			paramStr.Append('\n');
			Write(paramStr.Ptr, paramStr.Length);
		}

		static bool gIsDebuggerPresent = IsDebuggerPresent;
		[LinkName("IsDebuggerPresent"), CallingConvention(.Stdcall), Import("kernel32.lib")]
		static extern int32 Internal_IsDebuggerPresent();

		public static bool IsDebuggerPresent
		{
#if BF_PLATFORM_WINDOWS
			get => gIsDebuggerPresent = Internal_IsDebuggerPresent() != 0;
#else
			get => false;
#endif
		}

		[Intrinsic("debugtrap")]
		public static extern void Break();

		[NoDebug]
		public static void SafeBreak()
		{
			if (gIsDebuggerPresent)
				Break();
		}

		public static void WriteMemory(Span<uint8> mem)
		{
			String str = scope .();
			for (int i < mem.Length)
			{
				if ((i != 0) && (i % 16 == 0))
					str.Append('\n');
				str.AppendF($" {mem.[Friend]mPtr[i]:X2}");
			}
			str.Append('\n');
			Write(str);
		}

		public static void WriteMemory<T>(T result)
		{
#unwarn
			WriteMemory(.((.)&result, sizeof(T)));
		}
	}
}
