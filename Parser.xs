/* $Id: Parser.xs,v 2.38 1999/11/22 15:32:42 gisle Exp $
 *
 * Copyright 1999, Gisle Aas.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the same terms as Perl itself.
 */

/* TODO:
 *   - write test scritps
 *   - write documentation
 *   - count chars, line numbers
 *   - utf8 mode (entities expand to utf8 chars)
 *   - option that make start tag attrs be returned as a hash
 *   - return partial text from literal/cdata mode
 *   - accum flags (filter out what enters @accum)
 *
 * PLAIN BUGS:
 *   - unbroken_text does not handle cdata sections.
 *
 * POSSIBLE OPTIMIZATIONS:
 *   - direct method calls
 *   - avoid building start tag tokens when start tags are
 *     ignored.
 *   - less need for leaving things in buf when unbroken_text
 *     option is enabled.
 *
 * MINOR "BUGS" (alias FEATURES):
 *   - no way to clear "bool_attr_val" which gives the name of
 *     the attribute as value.  Perhaps not really a problem.
 *   - <plaintext> should not end with </plaintext>; can't be
 *     escaped.
 *   - xml_mode should demand ";" at end of entity references
 */

/* #define MARKED_SECTION /**/

#ifdef __cplusplus
extern "C" {
#endif
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#ifdef __cplusplus
}
#endif

#include "patchlevel.h"
#if PATCHLEVEL <= 4 /* perl5.004 */

#ifndef PL_sv_undef
   #define PL_sv_undef sv_undef
   #define PL_sv_yes   sv_yes
#endif

#ifndef PL_hexdigit
   #define PL_hexdigit hexdigit
#endif

#if (PATCHLEVEL == 4 && SUBVERSION <= 4)
/* The newSVpvn function was introduced in perl5.004_05 */
static SV *
newSVpvn(char *s, STRLEN len)
{
    register SV *sv = newSV(0);
    sv_setpvn(sv,s,len);
    return sv;
}
#endif
#endif /* perl5.004 */

#define P_MAGIC 0x16091964

#include "hctype.h" /* isH...() macros */

#ifdef MARKED_SECTION
enum marked_section_t {
  MS_NONE = 0,
  MS_INCLUDE,
  MS_RCDATA,
  MS_CDATA,
  MS_IGNORE,
};
#endif

struct p_state {
  U32 magic;

  SV* buf;
  SV* pending_text;

  /* various boolean configuration attributes */
  bool strict_comment;
  bool strict_names;
  bool decode_text_entities;
  bool keep_case;
  bool xml_mode;
  bool v2_compat;
  bool pass_self;
  bool unbroken_text;
  bool attr_pos;

  /* special parsing modes */
  char* literal_mode;

#ifdef MARKED_SECTION
  /* marked section support */
  enum marked_section_t ms;
  AV* ms_stack;
  bool marked_sections;
#endif

  /* various */
  SV* bool_attr_val;
  AV* accum;

  /* callbacks */
  SV* text_cb;
  SV* start_cb;
  SV* end_cb;
  SV* decl_cb;
  SV* com_cb;
  SV* pi_cb;
  SV* default_cb;
};
typedef struct p_state PSTATE;


static
struct literal_tag {
  int len;
  char* str;
}
literal_mode_elem[] =
{
  {6, "script"},
  {5, "style"},
  {3, "xmp"},
  {9, "plaintext"},
  {0, 0}
};

static HV* entity2char;


static SV*
sv_lower(SV* sv)
{
   STRLEN len;
   char *s = SvPV_force(sv, len);
   for (; len--; s++)
	*s = toLOWER(*s);
   return sv;
}

static SV*
decode_entities(SV* sv, HV* entity2char)
{
  STRLEN len;
  char *s = SvPV_force(sv, len);
  char *t = s;
  char *end = s + len;
  char *ent_start;

  char *repl;
  STRLEN repl_len;
  char buf[1];
  

  while (s < end) {
    assert(t <= s);

    if ((*t++ = *s++) != '&')
      continue;

    ent_start = s;
    repl = 0;

    if (*s == '#') {
      int num = 0;
      /* currently this code is limited to numeric references with values
       * below 256.  Doing more need Unicode support.
       */

      s++;
      if (*s == 'x' || *s == 'X') {
	char *tmp;
	s++;
	while (*s) {
	  char *tmp = strchr(PL_hexdigit, *s);
	  if (!tmp)
	    break;
	  s++;
	  if (num < 256) {
	    num = num << 4 | ((tmp - PL_hexdigit) & 15);
	  }
	}
      }
      else {
	while (isDIGIT(*s)) {
	  if (num < 256)
	    num = num*10 + (*s - '0');
	  s++;
	}
      }
      if (num && num < 256) {
	buf[0] = num;
	repl = buf;
	repl_len = 1;
      }
    }
    else {
      char *ent_name = s;
      while (isALNUM(*s))
	s++;
      if (ent_name != s && entity2char) {
	SV** svp = hv_fetch(entity2char, ent_name, s - ent_name, 0);
	if (svp)
	  repl = SvPV(*svp, repl_len);
      }
    }

    if (repl) {
      if (*s == ';')
	s++;
      t--;  /* '&' already copied, undo it */
      if (t + repl_len > s)
	croak("Growing string not supported yet");
      while (repl_len--)
	*t++ = *repl++;
    }
    else {
      while (ent_start < s)
	*t++ = *ent_start++;
    }
  }

  if (t != s) {
    *t = '\0';
    SvCUR_set(sv, t - SvPVX(sv));
  }
  return sv;
}

static void
html_default(PSTATE* p_state, char* beg, char *end, SV* self)
{	
  SV *cb = p_state->default_cb;
  if (beg == end)
    return;

  if (cb) {
    dSP;
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    if (p_state->pass_self)
      XPUSHs(self);
    XPUSHs(sv_2mortal(newSVpvn(beg, end - beg)));
    
    PUTBACK;

    perl_call_sv(cb, G_DISCARD);

    FREETMPS;
    LEAVE;
    
  }
}

static void
html_text(PSTATE* p_state, char* beg, char *end, int cdata, SV* self)
{
  AV *accum = p_state->accum;
  SV *cb = p_state->text_cb;

  SV* text;

  if (beg == end)
    return;

#ifdef MARKED_SECTION
  if (p_state->ms == MS_IGNORE)
    return;
#endif

  if (!accum && !cb) {
    html_default(p_state, beg, end, self);
    return;
  }

  if (p_state->unbroken_text) {
    if (p_state->pending_text)
      sv_catpvn(p_state->pending_text, beg, end - beg);
    else
      p_state->pending_text = newSVpvn(beg, end - beg);
    return;
  }

  text = newSVpvn(beg, end - beg);
  if (!cdata && p_state->decode_text_entities) {
    decode_entities(text, entity2char);
    cdata++;
  }

  if (accum) {
    AV* av = newAV();
    av_push(av, newSVpv("T", 1));
    av_push(av, text);
    if (cdata)
      av_push(av, newSVsv(&PL_sv_yes));
    av_push(accum, newRV_noinc((SV*)av));
    return;
  }

  if (cb) {
    dSP;
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    if (p_state->pass_self)
      XPUSHs(self);
    XPUSHs(sv_2mortal(text));
    XPUSHs(boolSV(cdata));
    PUTBACK;

    perl_call_sv(cb, G_DISCARD);

    FREETMPS;
    LEAVE;
  }
}


static void
flush_pending_text(PSTATE* p_state, SV* self)
{
  char *s;
  STRLEN len;
  bool old_unbroken_text;

  if (!p_state->pending_text)
    return;
  old_unbroken_text = p_state->unbroken_text;
  p_state->unbroken_text = 0;
  s = SvPV(p_state->pending_text, len);
  html_text(p_state, s, s+len, 0, self);
  SvREFCNT_dec(p_state->pending_text);
  p_state->pending_text = 0;
  p_state->unbroken_text = old_unbroken_text;
  return;
}


static void
html_end(PSTATE* p_state,
	 char *tag_beg, char *tag_end,
	 char *beg, char *end,
	 SV* self)
{
  AV *accum;
  SV *cb;

#ifdef MARKED_SECTION
  if (p_state->ms == MS_IGNORE)
    return;
#endif

  flush_pending_text(p_state, self);

  accum = p_state->accum;
  if (accum) {
    AV* av = newAV();
    SV* tag = newSVpv(tag_beg, tag_end - tag_beg);
    if (!p_state->keep_case && !p_state->xml_mode)
      sv_lower(tag);
    
    av_push(av, newSVpv("E", 1));
    av_push(av, tag);
    av_push(av, newSVpvn(beg, end - beg));
    av_push(accum, newRV_noinc((SV*)av));
    return;
  }

  cb = p_state->end_cb;
  if (cb) {
    SV *sv;
    dSP;
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    if (p_state->pass_self)
      XPUSHs(self);
    sv = sv_2mortal(newSVpv(tag_beg, tag_end - tag_beg));
    if (!p_state->keep_case && !p_state->xml_mode)
      sv_lower(sv);
    XPUSHs(sv);
    XPUSHs(sv_2mortal(newSVpvn(beg, end - beg)));
    PUTBACK;

    perl_call_sv(cb, G_DISCARD);

    FREETMPS;
    LEAVE;
    return;
  }

  html_default(p_state, beg, end, self);
}


static void
html_start(PSTATE* p_state,
	   char *tag_beg, char *tag_end,
	   AV* tokens,
	   int empty_tag,
	   char *beg, char *end,
	   SV* self)
{
  AV *accum = p_state->accum;
  SV *cb = p_state->start_cb;

  HV *attr;
  AV *attr_seq;

#ifdef MARKED_SECTION
  if (p_state->ms == MS_IGNORE)
    return;
#endif

  flush_pending_text(p_state, self);

  if ((accum || cb) && p_state->v2_compat) {
    /* need to construct an attr hash and an attr_seq array */
    int i;
    int len = av_len(tokens);
    attr = newHV();
    attr_seq = newAV();
    for (i = 0; i <= len; i += 2) {
      SV** svp1 = av_fetch(tokens, i,   0);
      SV** svp2 = av_fetch(tokens, i+1, 0);
      if (svp1) {
	av_push(attr_seq, SvREFCNT_inc(*svp1));
	if (svp2)
	  if (!hv_store_ent(attr, *svp1, SvREFCNT_inc(*svp2), 0))
	    SvREFCNT_dec(*svp2);
      }
    }
  }

  if (accum) {
    AV* av = newAV();
    SV* tag = newSVpv(tag_beg, tag_end - tag_beg);
    if (!p_state->keep_case && !p_state->xml_mode)
      sv_lower(tag);
    
    av_push(av, newSVpv("S", 1));
    av_push(av, tag);
    if (p_state->v2_compat) {
      av_push(av, newRV_noinc((SV*)attr));
      av_push(av, newRV_noinc((SV*)attr_seq));
    }
    else {
      av_push(av, newRV_inc((SV*)tokens));
    }
    av_push(av, newSVpv(beg, end - beg));
    av_push(accum, newRV_noinc((SV*)av));
  }
  else if (cb) {
    SV *sv;
    dSP;
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    if (p_state->pass_self)
      XPUSHs(self);
    sv = sv_2mortal(newSVpv(tag_beg, tag_end - tag_beg));
    if (!p_state->keep_case && !p_state->xml_mode)
      sv_lower(sv);
    XPUSHs(sv);
    if (p_state->v2_compat) {
      XPUSHs(sv_2mortal(newRV_noinc((SV*)attr)));
      XPUSHs(sv_2mortal(newRV_noinc((SV*)attr_seq)));
    }
    else {
      XPUSHs(sv_2mortal(newRV_inc((SV*)tokens)));
    }
    XPUSHs(sv_2mortal(newSVpvn(beg, end - beg)));
    PUTBACK;

    perl_call_sv(cb, G_DISCARD);

    FREETMPS;
    LEAVE;
  }
  else {
    html_default(p_state, beg, end, self);
    return;
  }

  if (empty_tag)
    html_end(p_state, tag_beg, tag_end, tag_beg, tag_beg, self);
}


static void
html_process(PSTATE* p_state,
	     char *pi_beg, char *pi_end,
	     char *beg, char *end,
	     SV* self)
{
  AV *accum;
  SV *cb;

#ifdef MARKED_SECTION
  if (p_state->ms == MS_IGNORE)
    return;
#endif

  flush_pending_text(p_state, self);

  accum = p_state->accum;
  if (accum) {
    AV* av = newAV();
    av_push(av, newSVpv("PI", 2));
    av_push(av, newSVpvn(pi_beg, pi_end - pi_beg));
    av_push(av, newSVpvn(beg, end - beg));
    av_push(accum, newRV_noinc((SV*)av));
    return;
  }

  cb = p_state->pi_cb;
  if (cb) {
    dSP;
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    if (p_state->pass_self)
      XPUSHs(self);
    XPUSHs(sv_2mortal(newSVpvn(pi_beg, pi_end - pi_beg)));
    XPUSHs(sv_2mortal(newSVpvn(beg, end - beg)));
    PUTBACK;

    perl_call_sv(cb, G_DISCARD);

    FREETMPS;
    LEAVE;
    return;
  }

  html_default(p_state, beg, end, self);
}


static void
html_comment(PSTATE* p_state, char *beg, char *end, SV* self)
{
  AV *accum;
  SV *cb;

#ifdef MARKED_SECTION
  if (p_state->ms == MS_IGNORE)
    return;
#endif

  flush_pending_text(p_state, self);

  accum = p_state->accum;
  if (accum) {
    AV* av = newAV();
    av_push(av, newSVpv("C", 1));
    av_push(av, newSVpvn(beg, end - beg));
    av_push(accum, newRV_noinc((SV*)av));
    return;
  }

  cb = p_state->com_cb;
  if (cb) {
    dSP;
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    if (p_state->pass_self)
      XPUSHs(self);
    XPUSHs(sv_2mortal(newSVpvn(beg, end - beg)));
    PUTBACK;

    perl_call_sv(cb, G_DISCARD);

    FREETMPS;
    LEAVE;
  }
}


static void
html_decl(PSTATE* p_state, AV* tokens, char *beg, char *end, SV* self)
{
  AV *accum;
  SV *cb;

#ifdef MARKED_SECTION
  if (p_state->ms == MS_IGNORE)
    return;
#endif

  flush_pending_text(p_state, self);

  accum = p_state->accum;
  if (accum) {
    AV* av = newAV();
    av_push(av, newSVpv("D", 1));
    if (!p_state->v2_compat)
      av_push(av, newRV_inc((SV*)tokens));
    av_push(av, newSVpv(beg, end - beg));
    av_push(accum, newRV_noinc((SV*)av));
    return;
  }

  cb = p_state->decl_cb;
  if (cb) {
    dSP;
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    if (p_state->pass_self)
      XPUSHs(self);
    if (!p_state->v2_compat)
      XPUSHs(sv_2mortal(newRV_inc((SV*)tokens)));
    XPUSHs(sv_2mortal(newSVpvn(beg, end - beg)));
    PUTBACK;

    perl_call_sv(cb, G_DISCARD);

    FREETMPS;
    LEAVE;
    return;
  }

  html_default(p_state, beg-2, end+1, self);
}



static char*
html_parse_comment(PSTATE* p_state, char *beg, char *end, SV* self)
{
  char *s = beg;

  if (p_state->strict_comment) {
    AV* av = newAV();  /* used to collect comments until we seen them all */
    char *start_com = s;  /* also used to signal inside/outside */

    while (1) {
      /* try to locate "--" */
    FIND_DASH_DASH:
      /* printf("find_dash_dash: [%s]\n", s); */
      while (s < end && *s != '-' && *s != '>')
	s++;

      if (s == end) {
	SvREFCNT_dec(av);
	return beg;
      }

      if (*s == '>') {
	s++;
	if (start_com)
	  goto FIND_DASH_DASH;
	
	/* we are done recognizing all comments, make callbacks */
	if (!p_state->accum && !p_state->com_cb)
	    html_default(p_state, beg-4, s, self);
	else {
	  int i;
	  int len = av_len(av);
	  for (i = 0; i <= len; i++) {
	    SV** svp = av_fetch(av, i, 0);
	    if (svp) {
	      STRLEN len;
	      char *s = SvPV(*svp, len);
	      html_comment(p_state, s, s+len, self);
	    }
	  }
	}

	SvREFCNT_dec(av);
	return s;
      }

      s++;
      if (s == end) {
	SvREFCNT_dec(av);
	return beg;
      }

      if (*s == '-') {
	/* two dashes in a row seen */
	s++;
	/* do something */
	if (start_com) {
	  av_push(av, newSVpvn(start_com, s - start_com - 2));
	  start_com = 0;
	}
	else {
	  start_com = s;
	}
      }
    }
  }

  else { /* non-strict comment */
    char *end_com;
    /* try to locate /--\s*>/ which signals end-of-comment */
  LOCATE_END:
    while (s < end && *s != '-')
      s++;
    end_com = s;
    if (s < end) {
      s++;
      if (s < end && *s == '-') {
	s++;
	while (isHSPACE(*s))
	  s++;
	if (s < end && *s == '>') {
	  s++;
	  /* yup */
	  if (!p_state->accum && !p_state->com_cb)
	    html_default(p_state, beg-4, s, self);
	  else
	    html_comment(p_state, beg, end_com, self);
	  return s;
	}
      }
      if (s < end) {
	s = end_com + 2;
	goto LOCATE_END;
      }
    }
    
    if (s == end)
      return beg;
  }

  return 0;
}

#ifdef MARKED_SECTION

static void
marked_section_update(PSTATE* p_state)
{
  /* we look at p_state->ms_stack to determine p_state->ms */
  AV* ms_stack = p_state->ms_stack;
  p_state->ms = MS_NONE;

  if (ms_stack) {
    int i;
    int stack_len = av_len(ms_stack);
    int stack_idx;
    for (stack_idx = 0; stack_idx <= stack_len; stack_idx++) {
      SV** svp = av_fetch(ms_stack, stack_idx, 0);
      if (svp) {
	AV* tokens = (AV*)SvRV(*svp);
	int tokens_len = av_len(tokens);
	int i;
	assert(SvTYPE(tokens) == SVt_PVAV);
	for (i = 0; i <= tokens_len; i++) {
	  SV** svp = av_fetch(tokens, i, 0);
	  if (svp) {
	    STRLEN len;
	    char *token_str = SvPV(*svp, len);
	    enum marked_section_t token;
	    if (strEQ(token_str, "include"))
	      token = MS_INCLUDE;
	    else if (strEQ(token_str, "rcdata"))
	      token = MS_RCDATA;
	    else if (strEQ(token_str, "cdata"))
	      token = MS_CDATA;
	    else if (strEQ(token_str, "ignore"))
	      token = MS_IGNORE;
	    else
	      token = MS_NONE;
	    if (p_state->ms < token)
	      p_state->ms = token;
	  }
	}
      }
    }
  }
  /* printf("MS %d\n", p_state->ms); */
  return;
}


static char*
html_parse_marked_section(PSTATE* p_state, char *beg, char *end, SV* self)
{
  char *s = beg;
  AV* tokens = 0;

  if (!p_state->marked_sections)
    return 0;

 FIND_NAMES:
  while (isHSPACE(*s))
    s++;
  while (isHNAME_FIRST(*s)) {
    char *name_start = s;
    char *name_end;
    s++;
    while (isHNAME_CHAR(*s))
      s++;
    name_end = s;
    while (isHSPACE(*s))
      s++;
    if (s == end)
      goto PREMATURE;

    if (!tokens)
      tokens = newAV();
    av_push(tokens, sv_lower(newSVpvn(name_start, name_end - name_start)));
  }
  if (*s == '-') {
    s++;
    if (*s == '-') {
      /* comment */
      s++;
      while (1) {
	while (s < end && *s != '-')
	  s++;
	if (s == end)
	  goto PREMATURE;

	s++;  /* skip first '-' */
	if (*s == '-') {
	  s++;
	  /* comment finished */
	  goto FIND_NAMES;
	}
      }      
    }
    else
      goto FAIL;
      
  }
  if (*s == '[') {
    s++;
    /* yup */

    if (!tokens) {
      tokens = newAV();
      av_push(tokens, newSVpvn("include", 7));
    }

    if (!p_state->ms_stack)
      p_state->ms_stack = newAV();
    av_push(p_state->ms_stack, newRV_noinc((SV*)tokens));
    marked_section_update(p_state);
    return s;
  }

 FAIL:
  SvREFCNT_dec(tokens);
  return 0; /* not yet implemented */
  
 PREMATURE:
  SvREFCNT_dec(tokens);
  return beg;
}
#endif

static char*
html_parse_decl(PSTATE* p_state, char *beg, char *end, SV* self)
{
  char *s = beg + 2;

  if (*s == '-') {
    /* comment? */

    char *tmp;
    s++;
    if (s == end)
      return beg;

    if (*s != '-')
      return 0;  /* nope, illegal */

    /* yes, two dashes seen */
    s++;

    tmp = html_parse_comment(p_state, s, end, self);
    return (tmp == s) ? beg : tmp;
  }

#ifdef MARKED_SECTION
  if (*s == '[') {
    /* marked section */
    char *tmp;
    s++;
    tmp = html_parse_marked_section(p_state, s, end, self);
    return (tmp == s) ? beg : tmp;
  }
#endif

  if (*s == '>') {
    /* make <!> into empty comment <SGML Handbook 36:32> */
    s++;
    if (!p_state->accum && !p_state->com_cb)
      html_default(p_state, beg, s, self);
    else
      html_comment(p_state, s-1, s-1, self);
    return s;
  }

  if (isALPHA(*s)) {
    AV* tokens = newAV();
    s++;
    /* declaration */
    while (s < end && isHNAME_CHAR(*s))
      s++;
    /* first word available */
    av_push(tokens, newSVpv(beg+2, s - beg));

    while (s < end && isHSPACE(*s)) {
      s++;
      while (s < end && isHSPACE(*s))
	s++;

      if (s == end)
	goto PREMATURE;

      if (*s == '"' || *s == '\'') {
	char *str_beg = s;
	s++;
	while (s < end && *s != *str_beg)
	  s++;
	if (s == end)
	  goto PREMATURE;
	s++;
	av_push(tokens, newSVpv(str_beg, s - str_beg));
      }
      else if (*s == '-') {
	/* comment */
	char *com_beg = s;
	s++;
	if (s == end)
	  goto PREMATURE;
	if (*s != '-')
	  goto FAIL;
	s++;

	while (1) {
	  while (s < end && *s != '-')
	    s++;
	  if (s == end)
	    goto PREMATURE;
	  s++;
	  if (s == end)
	    goto PREMATURE;
	  if (*s == '-') {
	    s++;
	    av_push(tokens, newSVpv(com_beg, s - com_beg));
	    break;
	  }
	}
      }
      else if (*s != '>') {
	/* plain word */
	char *word_beg = s;
	s++;
	while (s < end && isHNOT_SPACE_GT(*s))
	  s++;
	if (s == end)
	  goto PREMATURE;
	av_push(tokens, newSVpv(word_beg, s - word_beg));
      }
      else {
	break;
      }
    }

    if (s == end)
      goto PREMATURE;
    if (*s == '>') {
      s++;
      html_decl(p_state, tokens, beg+2, s-1, self);
      SvREFCNT_dec(tokens);
      return s;
    }

  FAIL:
    SvREFCNT_dec(tokens);
    return 0;

  PREMATURE:
    SvREFCNT_dec(tokens);
    return beg;

  }
  return 0;
}


static SV*
attr_val(PSTATE* p_state, char *tag_beg,
         char *prev_end, char *attr_beg,
	 char *val_beg, char *val_end,
         bool quote)
{
  if (p_state->attr_pos) {
    AV* av = newAV();
    av_extend(av, 3);
    av_push(av, newSViv(prev_end - tag_beg));
    av_push(av, newSViv(attr_beg - tag_beg));
    if (val_beg)
      av_push(av, newSViv(val_beg - tag_beg));
    else
      av_push(av, newSVsv(&PL_sv_undef));
    av_push(av, newSViv(val_end - tag_beg));
    return newRV_noinc((SV*)av);
  }
  else if (val_beg) {
    if (quote) {
      val_beg++;
      val_end--;
    }
    return decode_entities(newSVpvn(val_beg, val_end - val_beg), entity2char);
  }
  else {
     if (p_state->bool_attr_val)
        return newSVsv(p_state->bool_attr_val);
     return newSVpvn(attr_beg, val_end - attr_beg);
  }
}


static char*
html_parse_start(PSTATE* p_state, char *beg, char *end, SV* self)
{
  char *s = beg;
  char *tag_end;
  char *prev_end;
  AV* tokens = 0;
  SV* attr;
  int empty_tag = 0;  /* XML feature */

  hctype_t tag_name_first, tag_name_char;
  hctype_t attr_name_first, attr_name_char;

  if (p_state->strict_names) {
    tag_name_first = attr_name_first = HCTYPE_NAME_FIRST;
    tag_name_char  = attr_name_char  = HCTYPE_NAME_CHAR;
  }
  else if (p_state->xml_mode) {
    tag_name_first = tag_name_char = HCTYPE_NOT_SPACE_SLASH_GT;
    attr_name_first = HCTYPE_NOT_SPACE_SLASH_GT;
    attr_name_char  = HCTYPE_NOT_SPACE_EQ_SLASH_GT;
  }
  else {
    tag_name_first = tag_name_char = HCTYPE_NOT_SPACE_GT;
    attr_name_first = HCTYPE_NOT_SPACE_GT;
    attr_name_char  = HCTYPE_NOT_SPACE_EQ_GT;
  }


  assert(beg[0] == '<' && isHNAME_FIRST(beg[1]) && end - beg > 2);
  s += 2;

  while (s < end && isHCTYPE(*s, tag_name_char))
    s++;
  tag_end = s;
  prev_end = tag_end;
  while (isHSPACE(*s))
    s++;
  if (s == end)
    goto PREMATURE;

  tokens = newAV();

  while (isHCTYPE(*s, attr_name_first)) {
    /* attribute */
    char *attr_beg = s;
    s++;
    while (s < end && isHCTYPE(*s, attr_name_char))
      s++;
    if (s == end)
      goto PREMATURE;

    attr = newSVpv(attr_beg, s - attr_beg);
    if (!p_state->keep_case && !p_state->xml_mode)
      sv_lower(attr);
    av_push(tokens, attr);

    while (isHSPACE(*s))
      s++;
    if (s == end)
      goto PREMATURE;

    if (*s == '=') {
      /* with a value */
      s++;
      while (isHSPACE(*s))
	s++;
      if (s == end)
	goto PREMATURE;
      if (*s == '>') {
	/* parse it similar to ="" */
	av_push(tokens, attr_val(p_state, beg, prev_end, attr_beg, s, s, 0));
	break;
      }
      if (*s == '"' || *s == '\'') {
	char *str_beg = s;
	s++;
	while (s < end && *s != *str_beg)
	  s++;
	if (s == end)
	  goto PREMATURE;
	s++;
	av_push(tokens, attr_val(p_state, beg, prev_end, attr_beg, str_beg, s, 1));
      }
      else {
	char *word_start = s;
	while (s < end && isHNOT_SPACE_GT(*s)) {
	  if (p_state->xml_mode && *s == '/')
	    break;
	  s++;
	}
	if (s == end)
	  goto PREMATURE;
	av_push(tokens, attr_val(p_state, beg, prev_end, attr_beg, word_start, s, 0));
      }
      prev_end = s;
      while (isHSPACE(*s))
	s++;
      if (s == end)
	goto PREMATURE;
    }
    else {
      char *attr_end = attr_beg + SvCUR(attr);
      av_push(tokens, attr_val(p_state, beg, prev_end, attr_beg,
			       0, attr_end, 0));
      prev_end = attr_end;
    }
  }

  if (p_state->xml_mode && *s == '/') {
    s++;
    if (s == end)
      goto PREMATURE;
    empty_tag = 1;
  }

  if (*s == '>') {
    s++;
    /* done */
    html_start(p_state, beg+1, tag_end, tokens, empty_tag, beg, s, self);
    SvREFCNT_dec(tokens);

    if (1) {
      /* find out if this start tag should put us into literal_mode
       */
      int i;
      int tag_len = tag_end - beg - 1;

      for (i = 0; literal_mode_elem[i].len; i++) {
	if (tag_len == literal_mode_elem[i].len) {
	  /* try to match it */
	  char *s = beg + 1;
	  char *t = literal_mode_elem[i].str;
	  int len = tag_len;
	  while (len) {
	    if (toLOWER(*s) != *t)
	      break;
	    s++;
	    t++;
	    if (!--len) {
	      /* found it */
	      p_state->literal_mode = literal_mode_elem[i].str;
	      /* printf("Found %s\n", p_state->literal_mode); */
	      goto END_OF_LITERAL_SEARCH;
	    }
	  }
	}
      }
    END_OF_LITERAL_SEARCH:
    }

    return s;
  }
  
  SvREFCNT_dec(tokens);
  return 0;

 PREMATURE:
  SvREFCNT_dec(tokens);
  return beg;
}

static char*
html_parse_end(PSTATE* p_state, char *beg, char *end, SV* self)
{
  char *s = beg+2;
  hctype_t name_first, name_char;

  if (p_state->strict_names) {
    name_first = HCTYPE_NAME_FIRST;
    name_char  = HCTYPE_NAME_CHAR;
  }
  else {
    name_first = name_char = HCTYPE_NOT_SPACE_GT;
  }

  if (isHCTYPE(*s, name_first)) {
    char *tag_start = s;
    char *tag_end;
    s++;
    while (s < end && isHCTYPE(*s, name_char))
      s++;
    tag_end = s;
    while (isHSPACE(*s))
      s++;
    if (s < end) {
      if (*s == '>') {
	s++;
	/* a complete end tag has been recognized */
	html_end(p_state, tag_start, tag_end, beg, s, self);
	return s;
      }
    }
    else {
      return beg;
    }
  }
  return 0;
}

static char*
html_parse_process(PSTATE* p_state, char *beg, char *end, SV* self)
{
  char *s = beg + 2;
  /* processing instruction */
  char *pi_end;

 FIND_PI_END:
  while (s < end && *s != '>')
    s++;
  if (*s == '>') {
    pi_end = s;
    s++;

    if (p_state->xml_mode) {
      /* XML processing instructions are ended by "?>" */
      if (s - beg < 4 || s[-2] != '?')
	goto FIND_PI_END;
      pi_end = s - 2;
    }

    /* a complete processing instruction seen */
    html_process(p_state, beg+2, pi_end, beg, s, self);
    return s;
  }
  else {
    return beg;
  }
  return 0;
}

static char*
html_parse_null(PSTATE* p_state, char *beg, char *end, SV* self)
{
  return 0;
}

#include "pfunc.h"  /* declares the html_parsefunc[] */

static void
html_parse(PSTATE* p_state,
	   SV* chunk,
	   SV* self)
{
  char *s, *t, *end, *new_pos;
  STRLEN len;

  if (!chunk || !SvOK(chunk)) {
    /* EOF */
    if (p_state->buf && SvOK(p_state->buf)) {
      /* flush it */
      STRLEN len;
      char *s = SvPV(p_state->buf, len);
      html_text(p_state, s, s+len, 0, self);
      flush_pending_text(p_state, self);
      SvREFCNT_dec(p_state->buf);
      p_state->buf = 0;
    }
    return;
  }

  if (p_state->buf && SvOK(p_state->buf)) {
    sv_catsv(p_state->buf, chunk);
    s = SvPV(p_state->buf, len);
  }
  else {
    s = SvPV(chunk, len);
  }

  if (!len)
    return; /* nothing to do */

  t = s;
  end = s + len;

  while (1) {
    /*
     * At the start of this loop we will always be ready for eating text
     * or a new tag.  We will never be inside some tag.  The 't' point
     * to where we started and the 's' is advanced as we go.
     */

    while (p_state->literal_mode) {
      char *l = p_state->literal_mode;
      char *end_text;

      while (s < end && *s != '<')
	s++;

      if (s == end) {
	s = t;
	goto DONE;
      }

      end_text = s;
      s++;
      
      /* here we rely on '\0' termination of perl svpv buffers */
      if (*s == '/') {
	s++;
	while (*l && toLOWER(*s) == *l) {
	  s++;
	  l++;
	}

	if (!*l) {
	  /* matched it all */
	  char *end_tag = s;
	  while (isHSPACE(*s))
	    s++;
	  if (*s == '>') {
	    s++;
	    html_text(p_state, t, end_text, 1, self);
	    html_end(p_state, end_text+2, end_tag,
		     end_text, s, self);
	    p_state->literal_mode = 0;
	    t = s;
	  }
	}
      }
    }

#ifdef MARKED_SECTION
    while (p_state->ms == MS_CDATA || p_state->ms == MS_RCDATA) {
      while (s < end && *s != ']')
	s++;
      if (*s == ']') {
	char *end_text = s;
	s++;
	if (*s == ']') {
	  s++;
	  if (*s == '>') {
	    s++;
	    if (*s == '\n')
	      s++;
	    /* marked section end */
	    html_text(p_state, t, end_text, (p_state->ms == MS_CDATA), self);
	    t = s;
	    SvREFCNT_dec(av_pop(p_state->ms_stack));
	    marked_section_update(p_state);
	    continue;
	  }
	}
      }
      if (s == end) {
	s = t;
	goto DONE;
      }
    }
#endif

    /* first we try to match as much text as possible */
    while (s < end && *s != '<') {
#ifdef MARKED_SECTION
      if (p_state->ms && *s == ']') {
	char *end_text = s;
	s++;
	if (*s == ']') {
	  s++;
	  if (*s == '>') {
	    s++;
	    if (*s == '\n')
	      s++;
	    html_text(p_state, t, end_text, 0, self);
	    SvREFCNT_dec(av_pop(p_state->ms_stack));
	    marked_section_update(p_state);    
	    t = s;
	    continue;
	  }
	}
      }
#endif
      s++;
    }
    if (s != t) {
      if (*s == '<') {
	html_text(p_state, t, s, 0, self);
	t = s;
      }
      else {
	s--;
	if (isHSPACE(*s)) {
	  /* wait with white space at end */
	  while (s >= t && isHSPACE(*s))
	    s--;
	}
	else {
	  /* might be a chopped up entities/words */
	  while (s >= t && !isHSPACE(*s))
	    s--;
	  while (s >= t && isHSPACE(*s))
	    s--;
	}
	s++;
	html_text(p_state, t, s, 0, self);
	break;
      }
    }

    if (end - s < 3)
      break;

    /* next char is known to be '<' and pointed to by 't' as well as 's' */
    s++;

    if ( (new_pos = html_parsefunc[*s](p_state, t, end, self))) {
      if (new_pos == t) {
	/* no progress, need more data to know what it is */
	s = t;
	break;
      }
      t = s = new_pos;
    }

    /* if we get out here then this was not a conforming tag, so
     * treat it is plain text at the top of the loop again (we
     * have already skipped past the "<").
     */
  }

 DONE:

  if (s == end) {
    if (p_state->buf) {
      SvOK_off(p_state->buf);
    }
  }
  else {
    /* need to keep rest in buffer */
    if (p_state->buf) {
      /* chop off some chars at the beginning */
      if (SvOK(p_state->buf))
	sv_chop(p_state->buf, s);
      else
	sv_setpvn(p_state->buf, s, end - s);
    }
    else {
      p_state->buf = newSVpv(s, end - s);
    }
  }
  return;
}



static PSTATE*
get_pstate(SV* sv)
{
  HV* hv;
  SV** svp;

  sv = SvRV(sv);
  if (!sv || SvTYPE(sv) != SVt_PVHV)
    croak("Not a reference to a hash");
  hv = (HV*)sv;
  svp = hv_fetch(hv, "_parser_xs_state", 16, 0);
  if (svp) {
    PSTATE* p = (PSTATE*)SvIV(*svp);
#ifdef P_MAGIC
    if (p->magic != P_MAGIC)
      croak("Bad magic in parser state object at %p", p);
#endif
    return p;
  }
  croak("Can't find '_parser_xs_state' element in HTML::Parser hash");
  return 0;
}



MODULE = HTML::Parser		PACKAGE = HTML::Parser

PROTOTYPES: DISABLE

void
_alloc_pstate(self)
	SV* self;
    PREINIT:
	PSTATE* pstate;
	SV* sv;
	HV* hv;
    CODE:
	sv = SvRV(self);
        if (!sv || SvTYPE(sv) != SVt_PVHV)
            croak("Self is not a reference to a hash");
	hv = (HV*)sv;

	Newz(56, pstate, 1, PSTATE);
#ifdef P_MAGIC
	pstate->magic = P_MAGIC;
#endif
	sv = newSViv((IV)pstate);
	SvREADONLY_on(sv);

	hv_store(hv, "_parser_xs_state", 16, sv, 0);

void
DESTROY(pstate)
	PSTATE* pstate
    CODE:
	SvREFCNT_dec(pstate->buf);
	SvREFCNT_dec(pstate->pending_text);
#ifdef MARKED_SECTION
        SvREFCNT_dec(pstate->ms_stack);
#endif
        SvREFCNT_dec(pstate->bool_attr_val);
        SvREFCNT_dec(pstate->accum);
	SvREFCNT_dec(pstate->text_cb);
	SvREFCNT_dec(pstate->start_cb);
	SvREFCNT_dec(pstate->end_cb);
	SvREFCNT_dec(pstate->decl_cb);
	SvREFCNT_dec(pstate->com_cb);
	SvREFCNT_dec(pstate->pi_cb);
	SvREFCNT_dec(pstate->default_cb);
	Safefree(pstate);


void
parse(self, chunk)
	SV* self;
	SV* chunk
    PREINIT:
	PSTATE* pstate = get_pstate(self);
    PPCODE:
	html_parse(pstate, chunk, self);
	XSRETURN(1); /* self */

SV*
strict_comment(pstate,...)
	PSTATE* pstate
    ALIAS:
	HTML::Parser::strict_comment = 1
	HTML::Parser::strict_names = 2
	HTML::Parser::decode_text_entities = 3
        HTML::Parser::keep_case = 4
        HTML::Parser::xml_mode = 5
	HTML::Parser::v2_compat = 6
        HTML::Parser::pass_self = 7
	HTML::Parser::unbroken_text = 8
        HTML::Parser::attr_pos = 9
        HTML::Parser::marked_sections = 10
    PREINIT:
	bool *attr;
    CODE:
        switch (ix) {
	case  1: attr = &pstate->strict_comment;       break;
	case  2: attr = &pstate->strict_names;         break;
	case  3: attr = &pstate->decode_text_entities; break;
	case  4: attr = &pstate->keep_case;            break;
	case  5: attr = &pstate->xml_mode;             break;
	case  6: attr = &pstate->v2_compat;            break;
	case  7: attr = &pstate->pass_self;            break;
	case  8: attr = &pstate->unbroken_text;        break;
	case  9: attr = &pstate->attr_pos;             break;
        case 10:
#ifdef MARKED_SECTION
		 attr = &pstate->marked_sections;      break;
#else
	         croak("marked sections not supported"); break;
#endif
	default:
	    croak("Unknown boolean attribute (%d)", ix);
        }
	RETVAL = boolSV(*attr);
	if (items > 1)
	    *attr = SvTRUE(ST(1));
    OUTPUT:
	RETVAL

SV*
bool_attr_value(pstate,...)
        PSTATE* pstate
    CODE:
	RETVAL = pstate->bool_attr_val ? newSVsv(pstate->bool_attr_val)
				       : &PL_sv_undef;
	if (items > 1) {
	    SvREFCNT_dec(pstate->bool_attr_val);
	    pstate->bool_attr_val = newSVsv(ST(1));
        }
    OUTPUT:
	RETVAL

SV*
accum(pstate,...)
	PSTATE* pstate
    CODE:
        RETVAL = pstate->accum ? newRV_inc((SV*)pstate->accum)
	                       : &PL_sv_undef;
        if (items > 1) {
	    SV* aref = ST(1);
            AV* av = (AV*)SvRV(aref);
            if (!av || SvTYPE(av) != SVt_PVAV)
		croak("accum argument is not an array reference");
	    SvREFCNT_dec(pstate->accum);
	    pstate->accum = av;
	    (void)SvREFCNT_inc(pstate->accum);
        }
    OUTPUT:
	RETVAL

void
callback(pstate, name_sv, cb)
	PSTATE* pstate
	SV* name_sv
	SV* cb
    PREINIT:
	STRLEN name_len;
	char *name = SvPV(name_sv, name_len);
	SV** svp = 0;
    CODE:
	switch (name_len) {
	case 3:
	    if (strEQ(name, "end"))
		svp = &pstate->end_cb;
	    break;
	case 4:
	    if (strEQ(name, "text"))
		svp = &pstate->text_cb;
	    break;
	case 5:
	    if (strEQ(name, "start"))
		svp = &pstate->start_cb;
	    break;
	case 7:
	    if (strEQ(name, "comment"))
		svp = &pstate->com_cb;
	    if (strEQ(name, "process"))
		svp = &pstate->pi_cb;
	    if (strEQ(name, "default"))
		svp = &pstate->default_cb;
	    break;
	case 11:
	    if (strEQ(name, "declaration"))
		svp = &pstate->decl_cb;
	    break;
	}

	if (svp) {
	    SvREFCNT_dec(*svp);
	    *svp = SvOK(cb) ? SvREFCNT_inc(cb) : 0;
	}
	else
	    croak("Can't access %s callback", name);


MODULE = HTML::Parser		PACKAGE = HTML::Entities

void
decode_entities(...)
    PREINIT:
        int i;
    PPCODE:
	if (GIMME_V == G_SCALAR && items > 1)
            items = 1;
	for (i = 0; i < items; i++) {
	    if (GIMME_V != G_VOID)
	        ST(i) = sv_2mortal(newSVsv(ST(i)));
	    else if (SvREADONLY(ST(i)))
		croak("Can't inline decode readonly string");
	    decode_entities(ST(i), entity2char);
	}
        XSRETURN(items);


MODULE = HTML::Parser		PACKAGE = HTML::Parser

BOOT:
    entity2char = perl_get_hv("HTML::Entities::entity2char", TRUE);
