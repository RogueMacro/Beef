// The local time zone on platforms without the Windows registry (Linux, macOS, ...).
//
// Reads the system's compiled tzfile (TZif, RFC 8536) from $TZ or /etc/localtime and turns its
// transitions into the AdjustmentRules the rest of TimeZoneInfo already understands: each rule covers
// a date range with one standard offset and at most one DST period per year, built per year from the
// transitions and merged across years that share them, plus a final open-ended rule from the file's
// POSIX TZ footer. A $TZ that names no file is parsed as a POSIX TZ string.
//
// Limits of the rule model (all historical or exotic):
// - A year is split into several rules where its standard or daylight offset changes, or where it has
//   several DST periods. Rules start at midnight, so up to 12 hours around such a change are off.
// - POSIX rule times outside 00:00-24:00 (e.g. "M3.5.0/-1", "M3.4.4/50") are followed exactly until
//   2100, then clamped into the day.
// - Offsets are rounded to whole minutes (only local mean time before ~1900 has seconds).

#if !BF_PLATFORM_WINDOWS

using System.Collections;
using System.IO;

namespace System
{
	extension TimeZoneInfo
	{
		const int64 cTzUnixEpochTicks = 621355968000000000;
		// Transitions outside these bounds (in Unix seconds) are clamped: before = initial state, after = ignored
		const int64 cTzMinUnixSeconds = -62135596800 + 2 * 86400;
		const int64 cTzMaxUnixSeconds = 253402300799 - 2 * 86400;
		const int32 cTzMaxRuleYear = 9998;
		// Last year for which a footer rule with out-of-day times is expanded into exact transitions
		const int32 cTzExactFooterYear = 2100;

		struct TzType
		{
			public int64 mOffset; // ticks east of UTC, whole minutes
			public bool mIsDst;
			public int32 mNameIdx;
		}

		struct TzTransition
		{
			public int64 mUnixSeconds;
			public int32 mType;
		}

		class TzData
		{
			public List<TzType> mTypes = new .() ~ delete _;
			public List<TzTransition> mTransitions = new .() ~ delete _;
			public String mNames = new .() ~ delete _;
			public String mFooter = new .() ~ delete _;
		}

		struct TzState : IEquatable<TzState>
		{
			public int64 mOffset;
			public bool mIsDst;

			public this(int64 offset, bool isDst)
			{
				mOffset = offset;
				mIsDst = isDst;
			}

			public bool Equals(TzState other)
			{
				return (mOffset == other.mOffset) && (mIsDst == other.mIsDst);
			}
		}

		struct TzEvent
		{
			public int64 mUtcTicks;
			public TzState mState;
		}

		// A stretch of one year with a single state, from the year start or an event to the next event or the year end
		struct TzSegment
		{
			public TzState mState;
			public int64 mStartUtc;
			public int64 mEndUtc;
		}

		struct TzPosixRule
		{
			public StringView mStdName;
			public StringView mDstName;
			public int64 mStdOffset;
			public int64 mDstOffset;
			public bool mHasDst;
			public TransitionTime mStart; // time clamped into the day
			public TransitionTime mEnd;
			public TransitionTime mStartDay; // the same dates at 00:00, plus the exact times
			public TransitionTime mEndDay;
			public int64 mStartSeconds;
			public int64 mEndSeconds;
			public bool mTimesClamped;
		}

		struct TzRuleSpan
		{
			public DateTime mStartDate;
			public DateTime mEndDate;
			public int64 mBaseDelta;
			public int64 mDaylightDelta; // 0 = no DST
			public TransitionTime mStart;
			public TransitionTime mEnd;
			public bool mHasMarker; // start or end is a beginning/end-of-year marker; such rules stay within one year
		}

		[CLink, CallingConvention(.Stdcall)]
		static extern int readlink(char8* path, char8* buf, int bufSize);

		static private TimeZoneInfo GetLocalTimeZoneFromTzFile()
		{
			String id = scope .();
			List<uint8> fileData = scope .();
			bool haveFile = false;
			String tzEnv = scope .();
			StringView posixStr = default;

			if ((Environment.GetEnvironmentVariable("TZ", tzEnv) case .Ok) && (!tzEnv.IsEmpty))
			{
				StringView tz = tzEnv;
				if (tz.StartsWith(':'))
					tz.RemoveFromStart(1);
				String path = scope .();
				if (tz.StartsWith('/'))
					path.Append(tz);
				else
					path.AppendF("/usr/share/zoneinfo/{}", tz);
				if (File.ReadAll(path, fileData) case .Ok)
				{
					haveFile = true;
					TzIdFromPath(path, id);
					if (id.IsEmpty)
						id.Append(tz);
				}
				else
				{
					// Not a file: a POSIX TZ string such as "CET-1CEST,M3.5.0,M10.5.0/3"
					fileData.Clear();
					posixStr = tz;
					id.Append(tz);
				}
			}
			else if (File.ReadAll("/etc/localtime", fileData) case .Ok)
			{
				haveFile = true;
				char8[1024] linkBuf = default;
				int linkLen = readlink("/etc/localtime", &linkBuf, 1023);
				if (linkLen > 0)
					TzIdFromPath(StringView(&linkBuf, linkLen), id);
			}
			else
				return Utc;

			TzData tzData = scope .();
			if (haveFile)
			{
				if (!TzParseFile(fileData, tzData))
					return Utc;
				posixStr = tzData.mFooter;
			}

			TzPosixRule posix = default;
			bool hasPosix = (!posixStr.IsEmpty) && TzParsePosix(posixStr, out posix);
			if ((!hasPosix) && (tzData.mTypes.IsEmpty))
				return Utc;

			if (id.IsEmpty)
				id.Append(c_localId);

			let timeZone = TzCreateTimeZone(id, tzData, hasPosix ? &posix : null);
			if (timeZone == null)
				return Utc;
			return timeZone;
		}

		static void TzIdFromPath(StringView path, String outId)
		{
			int idx = path.IndexOf("zoneinfo/");
			if (idx >= 0)
				outId.Append(path.Substring(idx + "zoneinfo/".Length));
		}

		static int64 TzRoundToMinute(int64 seconds)
		{
			return (int64)Math.Round(seconds / 60.0) * TimeSpan.TicksPerMinute;
		}

		// ---- TZif ----

		static uint32 TzReadBE32(Span<uint8> data, int pos)
		{
			return ((uint32)data[pos] << 24) | ((uint32)data[pos + 1] << 16) | ((uint32)data[pos + 2] << 8) | (uint32)data[pos + 3];
		}

		static uint64 TzReadBE64(Span<uint8> data, int pos)
		{
			return ((uint64)TzReadBE32(data, pos) << 32) | (uint64)TzReadBE32(data, pos + 4);
		}

		struct TzHeader
		{
			public char8 mVersion;
			public int mIsUtCnt;
			public int mIsStdCnt;
			public int mLeapCnt;
			public int mTimeCnt;
			public int mTypeCnt;
			public int mCharCnt;

			public int GetDataSize(int timeSize)
			{
				return mTimeCnt * timeSize + mTimeCnt + mTypeCnt * 6 + mCharCnt + mLeapCnt * (timeSize + 4) + mIsStdCnt + mIsUtCnt;
			}
		}

		static bool TzReadHeader(Span<uint8> data, ref int pos, out TzHeader header)
		{
			header = default;
			if (pos + 44 > data.Length)
				return false;
			if ((data[pos] != 'T') || (data[pos + 1] != 'Z') || (data[pos + 2] != 'i') || (data[pos + 3] != 'f'))
				return false;
			header.mVersion = (char8)data[pos + 4];
			header.mIsUtCnt = TzReadBE32(data, pos + 20);
			header.mIsStdCnt = TzReadBE32(data, pos + 24);
			header.mLeapCnt = TzReadBE32(data, pos + 28);
			header.mTimeCnt = TzReadBE32(data, pos + 32);
			header.mTypeCnt = TzReadBE32(data, pos + 36);
			header.mCharCnt = TzReadBE32(data, pos + 40);
			pos += 44;
			return true;
		}

		static bool TzParseFile(Span<uint8> data, TzData tzData)
		{
			int pos = 0;
			TzHeader header;
			if (!TzReadHeader(data, ref pos, out header))
				return false;
			int timeSize = 4;
			if (header.mVersion >= '2')
			{
				// Version 2+ repeats the data with 64-bit times after the version 1 block, followed by the POSIX footer
				pos += header.GetDataSize(4);
				if (!TzReadHeader(data, ref pos, out header))
					return false;
				timeSize = 8;
			}

			int dataSize = header.GetDataSize(timeSize);
			if ((header.mTypeCnt == 0) || (pos + dataSize > data.Length))
				return false;

			int timesPos = pos;
			int typeIdxPos = timesPos + header.mTimeCnt * timeSize;
			int typesPos = typeIdxPos + header.mTimeCnt;
			int namesPos = typesPos + header.mTypeCnt * 6;

			for (int i < header.mTypeCnt)
			{
				int typePos = typesPos + i * 6;
				TzType type;
				type.mOffset = TzRoundToMinute((int32)TzReadBE32(data, typePos));
				type.mIsDst = data[typePos + 4] != 0;
				type.mNameIdx = data[typePos + 5];
				tzData.mTypes.Add(type);
			}
			tzData.mNames.Append((char8*)&data[namesPos], header.mCharCnt);

			for (int i < header.mTimeCnt)
			{
				TzTransition transition;
				if (timeSize == 8)
					transition.mUnixSeconds = (int64)TzReadBE64(data, timesPos + i * 8);
				else
					transition.mUnixSeconds = (int32)TzReadBE32(data, timesPos + i * 4);
				transition.mType = data[typeIdxPos + i];
				if (transition.mType >= header.mTypeCnt)
					return false;
				tzData.mTransitions.Add(transition);
			}

			pos += dataSize;
			if ((timeSize == 8) && (pos < data.Length) && (data[pos] == '\n'))
			{
				int footerEnd = pos + 1;
				while ((footerEnd < data.Length) && (data[footerEnd] != '\n'))
					footerEnd++;
				tzData.mFooter.Append((char8*)&data[pos + 1], footerEnd - pos - 1);
			}
			return true;
		}

		static StringView TzGetName(TzData tzData, int32 nameIdx)
		{
			if (nameIdx >= tzData.mNames.Length)
				return "";
			StringView name = tzData.mNames.Substring(nameIdx);
			int nulIdx = name.IndexOf('\0');
			if (nulIdx >= 0)
				name.Length = nulIdx;
			return name;
		}

		// ---- POSIX TZ strings ----

		static bool TzParsePosixName(StringView str, ref int pos, out StringView name)
		{
			name = default;
			if ((pos < str.Length) && (str[pos] == '<'))
			{
				int endIdx = str.IndexOf('>', pos + 1);
				if (endIdx < 0)
					return false;
				name = str.Substring(pos + 1, endIdx - pos - 1);
				pos = endIdx + 1;
				return !name.IsEmpty;
			}
			int startIdx = pos;
			while ((pos < str.Length) && (str[pos].IsLetter))
				pos++;
			name = str.Substring(startIdx, pos - startIdx);
			return !name.IsEmpty;
		}

		// [+-]hh[:mm[:ss]] in seconds
		static bool TzParsePosixTime(StringView str, ref int pos, out int64 seconds)
		{
			seconds = 0;
			bool negative = false;
			if ((pos < str.Length) && ((str[pos] == '+') || (str[pos] == '-')))
			{
				negative = str[pos] == '-';
				pos++;
			}
			for (int field < 3)
			{
				if (field > 0)
				{
					if ((pos >= str.Length) || (str[pos] != ':'))
						break;
					pos++;
				}
				int64 value = 0;
				int digits = 0;
				while ((pos < str.Length) && (str[pos].IsDigit))
				{
					value = value * 10 + (str[pos] - '0');
					pos++;
					digits++;
				}
				if (digits == 0)
					return false;
				seconds += value * ((field == 0) ? 3600 : ((field == 1) ? 60 : 1));
			}
			if (negative)
				seconds = -seconds;
			return true;
		}

		static bool TzParsePosixNumber(StringView str, ref int pos, out int value)
		{
			value = 0;
			int digits = 0;
			while ((pos < str.Length) && (str[pos].IsDigit))
			{
				value = value * 10 + (str[pos] - '0');
				pos++;
				digits++;
			}
			return digits > 0;
		}

		// Jn, n or Mm.w.d, optionally followed by /time
		static bool TzParsePosixDate(StringView str, ref int pos, out TransitionTime transitionTime, out TransitionTime dayTransitionTime,
			out int64 timeSeconds)
		{
			transitionTime = default;
			dayTransitionTime = default;
			timeSeconds = 2 * 3600;
			if (pos >= str.Length)
				return false;

			char8 kind = str[pos];
			int month = 0;
			int week = 0;
			int dayOfWeek = 0;
			int julianDay = 0;
			if (kind == 'M')
			{
				pos++;
				if (!TzParsePosixNumber(str, ref pos, out month))
					return false;
				if ((pos >= str.Length) || (str[pos] != '.'))
					return false;
				pos++;
				if (!TzParsePosixNumber(str, ref pos, out week))
					return false;
				if ((pos >= str.Length) || (str[pos] != '.'))
					return false;
				pos++;
				if (!TzParsePosixNumber(str, ref pos, out dayOfWeek))
					return false;
				if ((month < 1) || (month > 12) || (week < 1) || (week > 5) || (dayOfWeek > 6))
					return false;
			}
			else
			{
				if (kind == 'J')
					pos++;
				if (!TzParsePosixNumber(str, ref pos, out julianDay))
					return false;
				// "n" counts from 0 and includes Feb 29; treat it like "Jn" (exact outside leap years)
				if (kind != 'J')
					julianDay++;
				julianDay = Math.Clamp(julianDay, 1, 365);
			}

			if ((pos < str.Length) && (str[pos] == '/'))
			{
				pos++;
				if (!TzParsePosixTime(str, ref pos, out timeSeconds))
					return false;
			}
			// TransitionTime holds a time within the day; POSIX allows -167..167 hours
			DateTime timeOfDay = DateTime(Math.Clamp(timeSeconds, 0, 86399) * TimeSpan.TicksPerSecond);

			if (kind == 'M')
			{
				transitionTime = TransitionTime.CreateFloatingDateRule(timeOfDay, month, week, (DayOfWeek)dayOfWeek);
				dayTransitionTime = TransitionTime.CreateFloatingDateRule(DateTime.MinValue, month, week, (DayOfWeek)dayOfWeek);
			}
			else
			{
				// 2001 is not a leap year, matching Jn's 365-day calendar
				DateTime date = DateTime(2001, 1, 1).AddDays(julianDay - 1);
				transitionTime = TransitionTime.CreateFixedDateRule(timeOfDay, date.Month, date.Day);
				dayTransitionTime = TransitionTime.CreateFixedDateRule(DateTime.MinValue, date.Month, date.Day);
			}
			return true;
		}

		static bool TzParsePosixRules(StringView str, ref int pos, ref TzPosixRule rule)
		{
			if ((pos >= str.Length) || (str[pos] != ','))
				return false;
			pos++;
			if (!TzParsePosixDate(str, ref pos, out rule.mStart, out rule.mStartDay, out rule.mStartSeconds))
				return false;
			if ((pos >= str.Length) || (str[pos] != ','))
				return false;
			pos++;
			if (!TzParsePosixDate(str, ref pos, out rule.mEnd, out rule.mEndDay, out rule.mEndSeconds))
				return false;
			rule.mTimesClamped = (rule.mStartSeconds < 0) || (rule.mStartSeconds >= 86400) || (rule.mEndSeconds < 0) || (rule.mEndSeconds >= 86400);
			return pos == str.Length;
		}

		// std offset [dst [offset] [,start[/time],end[/time]]]; POSIX offsets are positive west of UTC
		static bool TzParsePosix(StringView str, out TzPosixRule rule)
		{
			rule = default;
			int pos = 0;
			int64 offsetSeconds;
			if (!TzParsePosixName(str, ref pos, out rule.mStdName))
				return false;
			if (!TzParsePosixTime(str, ref pos, out offsetSeconds))
				return false;
			rule.mStdOffset = TzRoundToMinute(-offsetSeconds);
			if (pos == str.Length)
				return true;

			if (!TzParsePosixName(str, ref pos, out rule.mDstName))
				return false;
			rule.mDstOffset = rule.mStdOffset + TimeSpan.TicksPerHour;
			if ((pos < str.Length) && (str[pos] != ','))
			{
				if (!TzParsePosixTime(str, ref pos, out offsetSeconds))
					return false;
				rule.mDstOffset = TzRoundToMinute(-offsetSeconds);
			}

			if (pos == str.Length)
			{
				// No rule given (e.g. TZ="EST5EDT"): use the US rules, like glibc
				StringView usRules = ",M3.2.0,M11.1.0";
				int rulePos = 0;
				if (!TzParsePosixRules(usRules, ref rulePos, ref rule))
					return false;
			}
			else if (!TzParsePosixRules(str, ref pos, ref rule))
				return false;

			rule.mHasDst = rule.mDstOffset != rule.mStdOffset;
			return true;
		}

		// ---- Rule generation ----

		static void TzAddEvent(List<TzEvent> events, TzState initialState, int64 utcTicks, TzState state)
		{
			TzState prevState = events.IsEmpty ? initialState : events.Back.mState;
			if (state == prevState)
				return;
			if ((!events.IsEmpty) && (utcTicks <= events.Back.mUtcTicks))
				return;
			TzEvent event;
			event.mUtcTicks = utcTicks;
			event.mState = state;
			events.Add(event);
		}

		// The local year in which an event happens, by the wall clock just before it
		static int TzEventYear(List<TzEvent> events, TzState initialState, int idx)
		{
			int64 prevOffset = (idx == 0) ? initialState.mOffset : events[idx - 1].mState.mOffset;
			return DateTime(events[idx].mUtcTicks + prevOffset).Year;
		}

		// A floating rule ("the Nth/last weekday of the month") reproduces the date in its own year and lets
		// years with the same rule share one AdjustmentRule
		static TransitionTime TzTransitionTimeFromWallClock(int64 wallTicks)
		{
			DateTime wall = DateTime(wallTicks);
			DateTime timeOfDay = DateTime((wall.TimeOfDay.Ticks / TimeSpan.TicksPerMillisecond) * TimeSpan.TicksPerMillisecond);
			int day = wall.Day;
			// A floating rule stores Day = 1, so in January at 00:00:00 it would read as the beginning/end-of-year
			// marker (AdjustmentRule.IsStartDateMarkerForBeginningOfYear); use the fixed date there
			if ((wall.Month == 1) && (timeOfDay.Hour == 0) && (timeOfDay.Minute == 0) && (timeOfDay.Second == 0))
				return TransitionTime.CreateFixedDateRule(timeOfDay, 1, day);
			int daysInMonth = DateTime.DaysInMonth(wall.Year, wall.Month);
			int week = (day + 7 > daysInMonth) ? 5 : ((day - 1) / 7 + 1);
			return TransitionTime.CreateFloatingDateRule(timeOfDay, wall.Month, week, wall.DayOfWeek);
		}

		// Rules start at midnight: split a year at the midnight nearest to a change
		static DateTime TzNearestMidnight(int64 wallTicks)
		{
			return DateTime(wallTicks + TimeSpan.TicksPerDay / 2).Date;
		}

		static TransitionTime TzYearMarker()
		{
			// Jan 1 00:00 as a start means "the year starts in DST", as an end "the year ends in DST"
			return TransitionTime.CreateFixedDateRule(DateTime.MinValue, 1, 1);
		}

		static int64 TzSegmentLength(TzSegment segment)
		{
			return segment.mEndUtc - segment.mStartUtc;
		}

		// DST runs (consecutive DST segments) among segments [first, last]. With allowWrap, a run at the end and one at
		// the start form one period that wraps around the year (the southern hemisphere's summer).
		static void TzFindDstRuns(List<TzSegment> segments, int first, int last, bool allowWrap, List<(int first, int last)> runs)
		{
			for (int i = first; i <= last; i++)
			{
				if (!segments[i].mState.mIsDst)
					continue;
				if ((!runs.IsEmpty) && (runs.Back.last == i - 1))
					runs.Back.last = i;
				else
					runs.Add((i, i));
			}
			if ((allowWrap) && (runs.Count >= 2) && (runs[0].first == first) && (runs.Back.last == last))
			{
				runs.Back.last = runs[0].last;
				runs.RemoveAt(0);
			}
		}

		// The rule for segments [first, last] of a year, covering startDate..endDate. Returns false when the range needs
		// no rule (no DST and the standard offset equals the base offset).
		static bool TzMakeRule(List<TzSegment> segments, int first, int last, bool allowWrap, DateTime startDate, DateTime endDate,
			int64 baseOffset, out TzRuleSpan rule)
		{
			rule = default;
			rule.mStartDate = startDate;
			rule.mEndDate = endDate;

			int stdIdx = -1;
			int longestIdx = first;
			for (int i = first; i <= last; i++)
			{
				int64 length = TzSegmentLength(segments[i]);
				if (length > TzSegmentLength(segments[longestIdx]))
					longestIdx = i;
				if ((!segments[i].mState.mIsDst) && ((stdIdx < 0) || (length > TzSegmentLength(segments[stdIdx]))))
					stdIdx = i;
			}

			List<(int first, int last)> runs = scope .();
			TzFindDstRuns(segments, first, last, allowWrap, runs);

			// Several DST periods left in one range (only when it couldn't be split): keep the longest
			int bestRun = -1;
			int64 bestRunLength = 0;
			int bestDstIdx = -1;
			for (int runIdx < runs.Count)
			{
				let run = runs[runIdx];
				int64 runLength = 0;
				int dstIdx = run.first;
				int i = run.first;
				while (true)
				{
					runLength += TzSegmentLength(segments[i]);
					if (TzSegmentLength(segments[i]) > TzSegmentLength(segments[dstIdx]))
						dstIdx = i;
					if (i == run.last)
						break;
					i = (i == last) ? first : (i + 1);
				}
				if ((bestRun < 0) || (runLength > bestRunLength))
				{
					bestRun = runIdx;
					bestRunLength = runLength;
					bestDstIdx = dstIdx;
				}
			}

			if ((stdIdx < 0) || (bestRun < 0))
			{
				// No DST (or DST throughout): only the offset matters
				int64 offset = (stdIdx >= 0) ? segments[stdIdx].mState.mOffset : segments[longestIdx].mState.mOffset;
				rule.mBaseDelta = offset - baseOffset;
				return rule.mBaseDelta != 0;
			}

			let run = runs[bestRun];
			int64 stdOffset = segments[stdIdx].mState.mOffset;
			int64 dstOffset = segments[bestDstIdx].mState.mOffset;
			rule.mBaseDelta = stdOffset - baseOffset;
			rule.mDaylightDelta = dstOffset - stdOffset;
			if (rule.mDaylightDelta == 0)
				return rule.mBaseDelta != 0;

			// DST starts at a standard-time wall clock and ends at a daylight-time wall clock. A period that runs into
			// the start or end of the year uses the Jan 1 00:00 marker instead.
			bool wraps = run.first > run.last;
			if ((!wraps) && (run.first == 0))
			{
				rule.mStart = TzYearMarker();
				rule.mHasMarker = true;
			}
			else
				rule.mStart = TzTransitionTimeFromWallClock(segments[run.first].mStartUtc + stdOffset);
			if ((!wraps) && (run.last == segments.Count - 1))
			{
				rule.mEnd = TzYearMarker();
				rule.mHasMarker = true;
			}
			else
				rule.mEnd = TzTransitionTimeFromWallClock(segments[run.last].mEndUtc + dstOffset);
			return true;
		}

		static void TzAddRule(List<TzRuleSpan> rules, TzRuleSpan rule)
		{
			if (!rules.IsEmpty)
			{
				ref TzRuleSpan prev = ref rules.Back;
				if ((!prev.mHasMarker) && (!rule.mHasMarker) && (prev.mEndDate.AddDays(1) == rule.mStartDate) &&
					(prev.mBaseDelta == rule.mBaseDelta) && (prev.mDaylightDelta == rule.mDaylightDelta) &&
					((rule.mDaylightDelta == 0) || ((prev.mStart == rule.mStart) && (prev.mEnd == rule.mEnd))))
				{
					prev.mEndDate = rule.mEndDate;
					return;
				}
			}
			rules.Add(rule);
		}

		// Adds the rules for one year's segments. A rule holds one standard offset and one DST period, so a year whose
		// standard offset changes, or which has several DST periods, is split into date ranges.
		static void TzAddYearRules(int year, List<TzSegment> segments, int64 baseOffset, List<TzRuleSpan> rules)
		{
			DateTime yearStart = DateTime(year, 1, 1);
			DateTime yearEnd = DateTime(year, 12, 31);

			List<(int first, int last)> runs = scope .();
			TzFindDstRuns(segments, 0, segments.Count - 1, true, runs);
			// One offset each for standard and daylight time?
			bool oneOffsetEach = true;
			bool haveStd = false;
			bool haveDst = false;
			int64 stdOffset = 0;
			int64 dstOffset = 0;
			for (let segment in segments)
			{
				if (segment.mState.mIsDst)
				{
					if ((haveDst) && (segment.mState.mOffset != dstOffset))
						oneOffsetEach = false;
					haveDst = true;
					dstOffset = segment.mState.mOffset;
				}
				else
				{
					if ((haveStd) && (segment.mState.mOffset != stdOffset))
						oneOffsetEach = false;
					haveStd = true;
					stdOffset = segment.mState.mOffset;
				}
			}

			TzRuleSpan rule;
			if ((oneOffsetEach) && (runs.Count <= 1))
			{
				// The usual case: the whole year in one rule
				if (TzMakeRule(segments, 0, segments.Count - 1, true, yearStart, yearEnd, baseOffset, out rule))
					TzAddRule(rules, rule);
				return;
			}

			int chunkFirst = 0;
			DateTime chunkStart = yearStart;
			bool chunkHasStd = false;
			int64 chunkStdOffset = 0;
			bool chunkHasDst = false;
			for (int i < segments.Count)
			{
				let segment = segments[i];
				int newChunkFirst = -1;
				DateTime splitDate = default;
				if (!segment.mState.mIsDst)
				{
					// A new standard offset starts a new range on the day it takes effect
					if ((chunkHasStd) && (segment.mState.mOffset != chunkStdOffset))
					{
						newChunkFirst = i;
						splitDate = TzNearestMidnight(segment.mStartUtc + segment.mState.mOffset);
					}
				}
				else if ((i > 0) && (segments[i - 1].mState.mIsDst) && (segments[i - 1].mState.mOffset != segment.mState.mOffset))
				{
					// A new daylight offset within a DST period (e.g. double summer time) starts a new range on that day
					newChunkFirst = i;
					splitDate = TzNearestMidnight(segment.mStartUtc + segment.mState.mOffset);
				}
				else if ((chunkHasDst) && (i > 0) && (!segments[i - 1].mState.mIsDst))
				{
					// Another DST period starts a new range in the middle of the standard time before it
					let stdSegment = segments[i - 1];
					newChunkFirst = i - 1;
					splitDate = DateTime((stdSegment.mStartUtc + stdSegment.mEndUtc) / 2 + stdSegment.mState.mOffset).Date;
				}

				if ((newChunkFirst >= 0) && (splitDate > chunkStart) && (splitDate <= yearEnd))
				{
					if (TzMakeRule(segments, chunkFirst, i - 1, false, chunkStart, splitDate.AddDays(-1), baseOffset, out rule))
						TzAddRule(rules, rule);
					chunkFirst = newChunkFirst;
					chunkStart = splitDate;
					chunkHasDst = false;
					chunkHasStd = newChunkFirst < i;
					if (chunkHasStd)
						chunkStdOffset = segments[newChunkFirst].mState.mOffset;
				}

				if (segment.mState.mIsDst)
					chunkHasDst = true;
				else
				{
					chunkHasStd = true;
					chunkStdOffset = segment.mState.mOffset;
				}
			}
			if (TzMakeRule(segments, chunkFirst, segments.Count - 1, false, chunkStart, yearEnd, baseOffset, out rule))
				TzAddRule(rules, rule);
		}

		static TimeZoneInfo TzCreateTimeZone(StringView id, TzData tzData, TzPosixRule* posix)
		{
			// Events: changes of (offset, isDst), in UTC order
			TzState initialState = default;
			if (!tzData.mTypes.IsEmpty)
				initialState = .(tzData.mTypes[0].mOffset, tzData.mTypes[0].mIsDst);
			else
				initialState = .(posix.mStdOffset, false);

			List<TzEvent> events = scope .();
			// The last transition in the file, even one that changes nothing: slim files (zic -b slim) end with such a
			// transition to mark where the footer takes over
			int64 lastTransitionUtc = int64.MinValue;
			int lastTransitionYear = 0;
			for (let transition in tzData.mTransitions)
			{
				let type = tzData.mTypes[transition.mType];
				TzState state = .(type.mOffset, type.mIsDst);
				if (transition.mUnixSeconds < cTzMinUnixSeconds)
				{
					initialState = state;
					continue;
				}
				if (transition.mUnixSeconds > cTzMaxUnixSeconds)
					break;
				int64 utcTicks = transition.mUnixSeconds * TimeSpan.TicksPerSecond + cTzUnixEpochTicks;
				int64 prevOffset = events.IsEmpty ? initialState.mOffset : events.Back.mState.mOffset;
				lastTransitionUtc = utcTicks;
				lastTransitionYear = DateTime(utcTicks + prevOffset).Year;
				TzAddEvent(events, initialState, utcTicks, state);
			}

			// The base offset is the current standard offset
			int64 baseOffset = initialState.mOffset;
			if (posix != null)
				baseOffset = posix.mStdOffset;
			else
			{
				for (int i = events.Count - 1; i >= 0; i--)
				{
					if (!events[i].mState.mIsDst)
					{
						baseOffset = events[i].mState.mOffset;
						break;
					}
				}
			}

			List<TzRuleSpan> ruleSpans = scope .();
			int firstRuleYear = 1;
			if (lastTransitionUtc != int64.MinValue)
			{
				int firstYear = events.IsEmpty ? lastTransitionYear : TzEventYear(events, initialState, 0);
				int lastYear = lastTransitionYear;
				int endYear = lastYear;

				// Complete the last year from the footer's rule, plus one more year so it ends on a whole cycle. A rule
				// whose times don't fit in a TransitionTime is followed exactly for longer.
				if ((posix != null) && (posix.mHasDst))
				{
					endYear = lastYear + 1;
					if (posix.mTimesClamped)
						endYear = Math.Max(endYear, cTzExactFooterYear);
					endYear = Math.Min(endYear, cTzMaxRuleYear);
					TzState stdState = .(posix.mStdOffset, false);
					TzState dstState = .(posix.mDstOffset, true);
					for (int year = lastYear; year <= endYear; year++)
					{
						DateTime startDay;
						DateTime endDay;
						if (!(TransitionTimeToDateTime(year, posix.mStartDay) case .Ok(out startDay)))
							continue;
						if (!(TransitionTimeToDateTime(year, posix.mEndDay) case .Ok(out endDay)))
							continue;
						int64 startUtc = startDay.Ticks + posix.mStartSeconds * TimeSpan.TicksPerSecond - posix.mStdOffset;
						int64 endUtc = endDay.Ticks + posix.mEndSeconds * TimeSpan.TicksPerSecond - posix.mDstOffset;
						// The footer only applies after the file's last transition
						if (startUtc < endUtc)
						{
							if (startUtc > lastTransitionUtc)
								TzAddEvent(events, initialState, startUtc, dstState);
							if (endUtc > lastTransitionUtc)
								TzAddEvent(events, initialState, endUtc, stdState);
						}
						else
						{
							if (endUtc > lastTransitionUtc)
								TzAddEvent(events, initialState, endUtc, stdState);
							if (startUtc > lastTransitionUtc)
								TzAddEvent(events, initialState, startUtc, dstState);
						}
					}
				}
				firstYear = Math.Max(firstYear, 1);
				endYear = Math.Min(endYear, cTzMaxRuleYear);

				// Before the first transition
				if ((firstYear > 1) && (initialState.mOffset != baseOffset))
				{
					TzRuleSpan rule = default;
					rule.mStartDate = DateTime(1, 1, 1);
					rule.mEndDate = DateTime(firstYear - 1, 12, 31);
					rule.mBaseDelta = initialState.mOffset - baseOffset;
					TzAddRule(ruleSpans, rule);
				}

				List<TzSegment> segments = scope .();
				TzState state = initialState;
				int eventIdx = 0;
				// Events before firstYear (only possible after clamping) just set the state
				while ((eventIdx < events.Count) && (TzEventYear(events, initialState, eventIdx) < firstYear))
				{
					state = events[eventIdx].mState;
					eventIdx++;
				}
				for (int year = firstYear; year <= endYear; year++)
				{
					segments.Clear();
					TzSegment segment;
					segment.mState = state;
					segment.mStartUtc = DateTime(year, 1, 1).Ticks - state.mOffset;
					while ((eventIdx < events.Count) && (TzEventYear(events, initialState, eventIdx) <= year))
					{
						segment.mEndUtc = events[eventIdx].mUtcTicks;
						segments.Add(segment);
						state = events[eventIdx].mState;
						segment.mState = state;
						segment.mStartUtc = events[eventIdx].mUtcTicks;
						eventIdx++;
					}
					segment.mEndUtc = DateTime(year + 1, 1, 1).Ticks - state.mOffset;
					segments.Add(segment);

					TzAddYearRules(year, segments, baseOffset, ruleSpans);
				}
				firstRuleYear = endYear + 1;

				if (posix == null)
				{
					// No footer: the last state continues forever
					if ((state.mOffset != baseOffset) && (firstRuleYear <= cTzMaxRuleYear))
					{
						TzRuleSpan rule = default;
						rule.mStartDate = DateTime(firstRuleYear, 1, 1);
						rule.mEndDate = DateTime.MaxValue.Date;
						rule.mBaseDelta = state.mOffset - baseOffset;
						TzAddRule(ruleSpans, rule);
					}
				}
			}

			// The footer's rule from then on
			if ((posix != null) && (firstRuleYear <= cTzMaxRuleYear))
			{
				TzRuleSpan rule = default;
				rule.mStartDate = DateTime(firstRuleYear, 1, 1);
				rule.mEndDate = DateTime.MaxValue.Date;
				rule.mBaseDelta = posix.mStdOffset - baseOffset;
				if (posix.mHasDst)
				{
					rule.mDaylightDelta = posix.mDstOffset - posix.mStdOffset;
					rule.mStart = posix.mStart;
					rule.mEnd = posix.mEnd;
				}
				if ((rule.mDaylightDelta != 0) || (rule.mBaseDelta != 0))
					TzAddRule(ruleSpans, rule);
			}

			AdjustmentRule[] rules = null;
			defer
			{
				if (rules != null)
					DeleteContainerAndItems!(rules);
			}
			if (!ruleSpans.IsEmpty)
			{
				List<AdjustmentRule> ruleList = scope .();
				for (let span in ruleSpans)
				{
					// The validator checks base + DaylightDelta; drop the odd historical rule that would fail it
					if (UtcOffsetOutOfRange(TimeSpan(baseOffset + span.mDaylightDelta)))
						continue;
					AdjustmentRule rule;
					if (span.mDaylightDelta == 0)
					{
						rule = AdjustmentRule.[Friend]CreateAdjustmentRule(span.mStartDate, span.mEndDate, TimeSpan.Zero,
							TransitionTime.CreateFixedDateRule(DateTime.MinValue, 1, 1),
							TransitionTime.CreateFixedDateRule(DateTime.MinValue.AddMilliseconds(1), 1, 1),
							TimeSpan(span.mBaseDelta));
					}
					else
					{
						rule = AdjustmentRule.[Friend]CreateAdjustmentRule(span.mStartDate, span.mEndDate, TimeSpan(span.mDaylightDelta),
							span.mStart, span.mEnd, TimeSpan(span.mBaseDelta));
					}
					ruleList.Add(rule);
				}
				rules = new AdjustmentRule[ruleList.Count];
				ruleList.CopyTo(rules);
			}

			// Names: the footer's abbreviations, else the last standard / daylight types used
			StringView stdName = default;
			StringView dstName = default;
			if (posix != null)
			{
				stdName = posix.mStdName;
				dstName = posix.mDstName;
			}
			for (int i = tzData.mTransitions.Count - 1; i >= 0; i--)
			{
				let type = tzData.mTypes[tzData.mTransitions[i].mType];
				if ((!type.mIsDst) && (stdName.IsEmpty))
					stdName = TzGetName(tzData, type.mNameIdx);
				if ((type.mIsDst) && (dstName.IsEmpty))
					dstName = TzGetName(tzData, type.mNameIdx);
			}
			if ((stdName.IsEmpty) && (!tzData.mTypes.IsEmpty))
				stdName = TzGetName(tzData, tzData.mTypes[0].mNameIdx);
			if (stdName.IsEmpty)
				stdName = id;
			if (dstName.IsEmpty)
				dstName = stdName;

			TimeZoneInfo timeZone = new TimeZoneInfo();
			if (timeZone.Init(id, TimeSpan(baseOffset), id, stdName, dstName, rules, false) case .Err)
			{
				delete timeZone;
				return null;
			}
			return timeZone;
		}
	}
}

#endif
