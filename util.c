/* $Id: util.c,v 2.21 2004/11/10 13:32:56 gisle Exp $
 *
 * Copyright 1999-2001, Gisle Aas.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the same terms as Perl itself.
 */

#ifndef EXTERN
#define EXTERN extern
#endif


EXTERN SV*
sv_lower(pTHX_ SV* sv)
{
    STRLEN len;
    char *s = SvPV_force(sv, len);
    for (; len--; s++)
	*s = toLOWER(*s);
    return sv;
}

EXTERN int
strnEQx(const char* s1, const char* s2, STRLEN n, int ignore_case)
{
    while (n--) {
	if (ignore_case) {
	    if (toLOWER(*s1) != toLOWER(*s2))
		return 0;
	}
	else {
	    if (*s1 != *s2)
		return 0;
	}
	s1++;
	s2++;
    }
    return 1;
}

static void
grow_gap(pTHX_ SV* sv, STRLEN grow, char** t, char** s, char** e)
{
    /*
     SvPVX ---> AAAAAA...BBBBBB
                     ^   ^     ^
                     t   s     e
    */
    STRLEN t_offset = *t - SvPVX(sv);
    STRLEN s_offset = *s - SvPVX(sv);
    STRLEN e_offset = *e - SvPVX(sv);

    SvGROW(sv, e_offset + grow + 1);

    *t = SvPVX(sv) + t_offset;
    *s = SvPVX(sv) + s_offset;
    *e = SvPVX(sv) + e_offset;

    Move(*s, *s+grow, *e - *s, char);
    *s += grow;
    *e += grow;
}

EXTERN SV*
decode_entities(pTHX_ SV* sv, HV* entity2char)
{
    STRLEN len;
    char *s = SvPV_force(sv, len);
    char *t = s;
    char *end = s + len;
    char *ent_start;

    char *repl;
    STRLEN repl_len;
#ifdef UNICODE_ENTITIES
    char buf[UTF8_MAXLEN];
    int repl_utf8;
    int high_surrogate = 0;
#else
    char buf[1];
#endif

#if defined(__GNUC__) && defined(UNICODE_ENTITIES)
    /* gcc -Wall reports this variable as possibly used uninitialized */
    repl_utf8 = 0;
#endif

    while (s < end) {
	assert(t <= s);

	if ((*t++ = *s++) != '&')
	    continue;

	ent_start = s;
	repl = 0;

	if (*s == '#') {
	    UV num = 0;
	    UV prev = 0;
	    int ok = 0;
	    s++;
	    if (*s == 'x' || *s == 'X') {
		s++;
		while (*s) {
		    char *tmp = strchr(PL_hexdigit, *s);
		    if (!tmp)
			break;
		    num = num << 4 | ((tmp - PL_hexdigit) & 15);
		    if (prev && num <= prev) {
			/* overflow */
			ok = 0;
			break;
		    }
		    prev = num;
		    s++;
		    ok = 1;
		}
	    }
	    else {
		while (isDIGIT(*s)) {
		    num = num * 10 + (*s - '0');
		    if (prev && num < prev) {
			/* overflow */
			ok = 0;
			break;
		    }
		    prev = num;
		    s++;
		    ok = 1;
		}
	    }
	    if (ok) {
#ifdef UNICODE_ENTITIES
		if (!SvUTF8(sv) && num <= 255) {
		    buf[0] = (char) num;
		    repl = buf;
		    repl_len = 1;
		    repl_utf8 = 0;
		}
		else {
		    char *tmp;
		    if ((num & 0xFFFFFC00) == 0xDC00) {  /* low-surrogate */
			if (high_surrogate != 0) {
			    t -= 3; /* Back up past 0xFFFD */
			    num = ((high_surrogate - 0xD800) << 10) +
				(num - 0xDC00) + 0x10000;
			    high_surrogate = 0;
			} else {
			    num = 0xFFFD;
			}
		    }
		    else if ((num & 0xFFFFFC00) == 0xD800) { /* high-surrogate */
			high_surrogate = num;
			num = 0xFFFD;
		    }
		    else {
			high_surrogate = 0;
			/* otherwise invalid? */
			if ((num >= 0xFDD0 && num <= 0xFDEF) ||
			    ((num & 0xFFFE) == 0xFFFE) ||
			    num > 0x10FFFF)
			{
			    num = 0xFFFD;
			}
		    }

		    tmp = uvuni_to_utf8(buf, num);
		    repl = buf;
		    repl_len = tmp - buf;
		    repl_utf8 = 1;
		}
#else
		if (num <= 255) {
		    buf[0] = (char) num & 0xFF;
		    repl = buf;
		    repl_len = 1;
		}
#endif
	    }
	}
	else {
	    char *ent_name = s;
	    while (isALNUM(*s))
		s++;
	    if (ent_name != s && entity2char) {
		SV** svp = hv_fetch(entity2char, ent_name, s - ent_name, 0);
		if (svp) {
		    repl = SvPV(*svp, repl_len);
#ifdef UNICODE_ENTITIES
		    repl_utf8 = SvUTF8(*svp);
#endif
		}
	    }
#ifdef UNICODE_ENTITIES
	    high_surrogate = 0;
#endif
	}

	if (repl) {
	    char *repl_allocated = 0;
	    if (*s == ';')
		s++;
	    t--;  /* '&' already copied, undo it */

#ifdef UNICODE_ENTITIES
	    if (*s != '&') {
		high_surrogate = 0;
	    }

	    if (!SvUTF8(sv) && repl_utf8) {
		/* need to upgrade sv before we continue */
		STRLEN before_gap_len = t - SvPVX(sv);
		char *before_gap = bytes_to_utf8(SvPVX(sv), &before_gap_len);
		STRLEN after_gap_len = end - s;
		char *after_gap = bytes_to_utf8(s, &after_gap_len);

		sv_setpvn(sv, before_gap, before_gap_len);
		sv_catpvn(sv, after_gap, after_gap_len);
		SvUTF8_on(sv);

		Safefree(before_gap);
		Safefree(after_gap);

		s = t = SvPVX(sv) + before_gap_len;
		end = SvPVX(sv) + before_gap_len + after_gap_len;
	    }
	    else if (SvUTF8(sv) && !repl_utf8) {
		repl = bytes_to_utf8(repl, &repl_len);
		repl_allocated = repl;
	    }
#endif

	    if (t + repl_len > s) {
		/* need to grow the string */
		grow_gap(aTHX_ sv, repl_len - (s - t), &t, &s, &end);
	    }

	    /* copy replacement string into string */
	    while (repl_len--)
		*t++ = *repl++;

	    if (repl_allocated)
		Safefree(repl_allocated);
	}
	else {
	    while (ent_start < s)
		*t++ = *ent_start++;
	}
    }

    *t = '\0';
    SvCUR_set(sv, t - SvPVX(sv));

    return sv;
}
