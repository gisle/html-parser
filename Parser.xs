/* $Id: Parser.xs,v 2.17 1999/11/10 13:17:03 gisle Exp $
 *
 * Copyright 1999, Gisle Aas.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the same terms as Perl itself.
 */

/* TODO:
 *   - direct method calls
 *   - accum flags (filter out what enters @accum)
 *   - return partial text from literal mode
 *   - marked sections?
 *   - unicode support (whatever that means)
 *   - unicode character entities
 *   - count chars, line numbers
 *
 * MINOR "BUGS":
 *   - no way to clear "bool_attr_val" which gives the name of
 *     the attribute as value.  Perhaps not really a problem.
 *   - <plaintext> should not end with </plaintext>
 *   - xml_mode should demand ";" at end of entity references
 */

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


/* This is used to classify "letters" that can make up an HTML identifier
 * (tagname or attribute name) after the first strict ALFA char.  In addition
 * to what is allowed according to the SGML reference syntax we allow "_"
 * and ":".   The underscore is known to be used in Netscape bookmarks.html
 * files.  MicroSoft Excel use ":" in their HTML exports:
 *
 *  <A HREF="..." ADD_DATE="940656492" LAST_VISIT="941139558" LAST_MODIFIED="940656487">
 *  <div id="TSOH499L_24029" align=center x:publishsource="Excel">
 *
 *  HTML 4.0.1 now allows this.
 */

#define isHALPHA(c) (isALPHA(c) || (c) == '_' || (c) == ':')
#define isHALNUM(c) (isALNUM(c) || (c) == '.' || (c) == '-' || (c) == ':')


struct p_state {
  SV* buf;
  char* literal_mode;

  /* various boolean configuration attributes */
  int strict_comment;
  int decode_text_entities;
  int keep_case;
  int xml_mode;
  int v2_compat;
  int pass_cbdata;

  SV* bool_attr_val;
  AV* accum;

  SV* text_cb;
  SV* start_cb;
  SV* end_cb;
  SV* decl_cb;
  SV* com_cb;
  SV* pi_cb;
  SV* default_cb;
};
typedef struct p_state PSTATE;


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
	/* XXX lookup ent_name */
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
html_default(PSTATE* p_state, char* beg, char *end, SV* cbdata)
{	
  SV *cb = p_state->default_cb;
  if (beg == end)
    return;

  if (cb) {
    dSP;
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    if (p_state->pass_cbdata)
      XPUSHs(cbdata);
    XPUSHs(sv_2mortal(newSVpvn(beg, end - beg)));
    
    PUTBACK;

    perl_call_sv(cb, G_DISCARD);

    FREETMPS;
    LEAVE;
    
  }
}

static void
html_text(PSTATE* p_state, char* beg, char *end, int cdata, SV* cbdata)
{
  AV *accum = p_state->accum;
  SV *cb = p_state->text_cb;

  SV* text;

  if (beg == end)
    return;

  if (!accum && !cb) {
    html_default(p_state, beg, end, cbdata);
    return;
  }

  text = newSVpv(beg, end - beg);
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
    if (p_state->pass_cbdata)
      XPUSHs(cbdata);
    XPUSHs(sv_2mortal(text));
    XPUSHs(boolSV(cdata));
    PUTBACK;

    perl_call_sv(cb, G_DISCARD);

    FREETMPS;
    LEAVE;
  }
}


static void
html_end(PSTATE* p_state,
	 char *tag_beg, char *tag_end,
	 char *beg, char *end,
	 SV* cbdata)
{
  AV *accum;
  SV *cb;

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
    if (p_state->pass_cbdata)
      XPUSHs(cbdata);
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

  html_default(p_state, beg, end, cbdata);
}


static void
html_start(PSTATE* p_state,
	   char *tag_beg, char *tag_end,
	   AV* tokens,
	   int empty_tag,
	   char *beg, char *end,
	   SV* cbdata)
{
  AV *accum = p_state->accum;
  SV *cb = p_state->start_cb;

  HV *attr;
  AV *attr_seq;

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
    if (p_state->pass_cbdata)
      XPUSHs(cbdata);
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
    html_default(p_state, beg, end, cbdata);
    return;
  }

  if (empty_tag)
    html_end(p_state, tag_beg, tag_end, tag_beg, tag_beg, cbdata);
}


static void
html_process(PSTATE* p_state,
	     char *pi_beg, char *pi_end,
	     char *beg, char *end,
	     SV* cbdata)
{
  AV *accum;
  SV *cb;

  accum = p_state->accum;
  if (accum) {
    AV* av = newAV();
    av_push(av, newSVpv("PI", 2));
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
    if (p_state->pass_cbdata)
      XPUSHs(cbdata);
    XPUSHs(sv_2mortal(newSVpvn(pi_beg, pi_end - pi_beg)));
    XPUSHs(sv_2mortal(newSVpvn(beg, end - beg)));
    PUTBACK;

    perl_call_sv(cb, G_DISCARD);

    FREETMPS;
    LEAVE;
    return;
  }

  html_default(p_state, beg, end, cbdata);
}


static void
html_comment(PSTATE* p_state, char *beg, char *end, SV* cbdata)
{
  AV *accum;
  SV *cb;

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
    if (p_state->pass_cbdata)
      XPUSHs(cbdata);
    XPUSHs(sv_2mortal(newSVpvn(beg, end - beg)));
    PUTBACK;

    perl_call_sv(cb, G_DISCARD);

    FREETMPS;
    LEAVE;
  }
}


static void
html_decl(PSTATE* p_state, AV* tokens, char *beg, char *end, SV* cbdata)
{
  AV *accum;
  SV *cb;

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
    if (p_state->pass_cbdata)
      XPUSHs(cbdata);
    if (!p_state->v2_compat)
      XPUSHs(sv_2mortal(newRV_inc((SV*)tokens)));
    XPUSHs(sv_2mortal(newSVpvn(beg, end - beg)));
    PUTBACK;

    perl_call_sv(cb, G_DISCARD);

    FREETMPS;
    LEAVE;
    return;
  }

  html_default(p_state, beg-2, end+1, cbdata);
}



static char*
html_parse_comment(PSTATE* p_state, char *beg, char *end, SV* cbdata)
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
	    html_default(p_state, beg-4, s, cbdata);
	else {
	  int i;
	  int len = av_len(av);
	  for (i = 0; i <= len; i++) {
	    SV** svp = av_fetch(av, i, 0);
	    if (svp) {
	      STRLEN len;
	      char *s = SvPV(*svp, len);
	      html_comment(p_state, s, s+len, cbdata);
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
	while (s < end && isSPACE(*s))
	  s++;
	if (s < end && *s == '>') {
	  s++;
	  /* yup */
	  if (!p_state->accum && !p_state->com_cb)
	    html_default(p_state, beg-4, s, cbdata);
	  else
	    html_comment(p_state, beg, end_com, cbdata);
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



static char*
html_parse_decl(PSTATE* p_state, char *beg, char *end, SV* cbdata)
{
  char *s = beg;

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

    tmp = html_parse_comment(p_state, s, end, cbdata);
    return (tmp == s) ? beg : tmp;
  }

  if (isALPHA(*s)) {
    AV* tokens = newAV();
    s++;
    /* declaration */
    while (s < end && isHALNUM(*s))
      s++;
    /* first word available */
    av_push(tokens, newSVpv(beg, s - beg));

    while (s < end && isSPACE(*s)) {
      s++;
      while (s < end && isSPACE(*s))
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
	while (s < end && !isSPACE(*s) && *s != '>')
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
      html_decl(p_state, tokens, beg, s-1, cbdata);
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



static char*
html_parse_start(PSTATE* p_state, char *beg, char *end, SV* cbdata)
{
  char *s = beg;
  char *tag_end;
  AV* tokens = 0;
  SV* attr;
  int empty_tag = 0;  /* XML feature */

  assert(beg[0] == '<' && isHALPHA(beg[1]) && end - beg > 2);
  s += 2;

  while (s < end && isHALNUM(*s))
    s++;
  tag_end = s;
  while (s < end && isSPACE(*s))
    s++;
  if (s == end)
    goto PREMATURE;

  tokens = newAV();

  while (isHALPHA(*s)) {
    /* attribute */
    char *attr_beg = s;
    s++;
    while (s < end && isHALNUM(*s))
      s++;
    if (s == end)
      goto PREMATURE;

    attr = newSVpv(attr_beg, s - attr_beg);
    if (!p_state->keep_case && !p_state->xml_mode)
      sv_lower(attr);
    av_push(tokens, attr);

    while (s < end && isSPACE(*s))
      s++;
    if (s == end)
      goto PREMATURE;

    if (*s == '=') {
      /* with a value */
      s++;
      while (s < end && isSPACE(*s))
	s++;
      if (s == end)
	goto PREMATURE;
      if (*s == '>') {
	/* parse it similar to ="" */
	av_push(tokens, newSVpvn("", 0));
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
	av_push(tokens, decode_entities(newSVpvn(str_beg+1, s - str_beg - 2),
					entity2char));
      }
      else {
	char *word_start = s;
	while (s < end && !isSPACE(*s) && *s != '>') {
	  if (p_state->xml_mode && *s == '/')
	    break;
	  s++;
	}
	if (s == end)
	  goto PREMATURE;
	av_push(tokens, decode_entities(newSVpv(word_start, s - word_start),
					entity2char));
      }

      while (s < end && isSPACE(*s))
	s++;
      if (s == end)
	goto PREMATURE;
    }
    else {
      SV* sv = p_state->bool_attr_val;
      if (!sv)
	sv = attr;
      av_push(tokens, newSVsv(sv));
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
    html_start(p_state, beg+1, tag_end, tokens, empty_tag, beg, s, cbdata);
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



static void
html_parse(PSTATE* p_state,
	   SV* chunk,
	   SV* cbdata)
{
  char *s, *t, *end;
  STRLEN len;

#if 0
  {
    STRLEN len;
    char *s;

    printf("html_parse\n");
    if (p_state->buf) {
      s = SvPV(p_state->buf, len);
      printf("  buf   = [%s]\n", s);
    }
    if (chunk && SvOK(chunk)) {
      s = SvPV(chunk, len);
      printf("  chunk = [%s]\n", s);
    }
  }
#endif

  if (!chunk || !SvOK(chunk)) {
    /* EOF */
    if (p_state->buf && SvOK(p_state->buf)) {
      /* flush it */
      STRLEN len;
      char *s = SvPV(p_state->buf, len);
      html_text(p_state, s, s+len, 0, cbdata);
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
	while (*l && *s == *l) {
	  s++;
	  l++;
	}

	if (!*l) {
	  /* matched it all */
	  char *end_tag = s;
	  while (isSPACE(*s))
	    s++;
	  if (*s == '>') {
	    s++;
	    html_text(p_state, t, end_text, 1, cbdata);
	    html_end(p_state, end_text+2, end_tag,
		     end_text, s, cbdata);
	    p_state->literal_mode = 0;
	    t = s;
	  }
	}
      }
    }

    /* first we try to match as much text as possible */
    while (s < end && *s != '<')
      s++;
    if (s != t) {
      if (*s == '<') {
	html_text(p_state, t, s, 0, cbdata);
	t = s;
      }
      else {
	s--;
	if (isSPACE(*s)) {
	  /* wait with white space at end */
	  while (s >= t && isSPACE(*s))
	    s--;
	}
	else {
	  /* might be a chopped up entities/words */
	  while (s >= t && !isSPACE(*s))
	    s--;
	  while (s >= t && isSPACE(*s))
	    s--;
	}
	s++;
	html_text(p_state, t, s, 0, cbdata);
	break;
      }
    }

    if (end - s < 3)
      break;

    /* next char is known to be '<' */
    s++;

    if (isHALPHA(*s)) {
      /* start tag */
      char *new_pos = html_parse_start(p_state, t, end, cbdata);
      if (new_pos == t) {
	s = t;
	break;
      }	
      else if (new_pos)
	t = s = new_pos;
    }
    else if (*s == '/') {
      /* end tag */
      s++;
      if (isHALPHA(*s)) {
	char *tag_start = s;
	char *tag_end;
	s++;
	while (s < end && isHALNUM(*s))
	  s++;
	tag_end = s;
	while (s < end && isSPACE(*s))
	  s++;
	if (s < end) {
	  if (*s == '>') {
	    s++;
	    /* a complete end tag has been recognized */
	    html_end(p_state, tag_start, tag_end, t, s, cbdata);
	    t = s;
	  }
	}
	else {
	  s = t;
	  break;  /* need to see more stuff */
	}
      }
    }
    else if (*s == '!') {
      /* declaration or comment */
      char *new_pos;
      s++;
      new_pos = html_parse_decl(p_state, s, end, cbdata);
      if (new_pos == s) {
	/* no progress, need more */
	s = t;
	break;
      }
      else if (new_pos) {
	t = s = new_pos;
      }
    }
    else if (*s == '?') {
      /* processing instruction */
      char *pi_end;
      s++;
    FIND_PI_END:
      while (s < end && *s != '>')
	s++;
      if (*s == '>') {
	pi_end = s;
	s++;

	if (p_state->xml_mode) {
	  /* XML processing instructions are ended by "?>" */
	  if (s - t < 4 || s[-2] != '?')
	    goto FIND_PI_END;
	  pi_end = s - 2;
	}

	/* a complete processing instruction seen */
	html_process(p_state, t+2, pi_end, t, s, cbdata);
	t = s;
      }
      else {
	/* need more */
	s = t;
	break;
      }
    }

    /* if we get out here thene this was not a conforming tag, so
     * treat it is plain text.
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
  if (svp)
    return (PSTATE*)SvIV(*svp);
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
	sv = newSViv((IV)pstate);
	SvREADONLY_on(sv);

	hv_store(hv, "_parser_xs_state", 16, sv, 0);

void
DESTROY(pstate)
	PSTATE* pstate
    CODE:
	SvREFCNT_dec(pstate->buf);
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
	HTML::Parser::decode_text_entities = 2
        HTML::Parser::keep_case = 3
        HTML::Parser::xml_mode = 4
	HTML::Parser::v2_compat = 5
        HTML::Parser::pass_cbdata = 6
    PREINIT:
	int *attr;
    CODE:
        switch (ix) {
	case 1: attr = &pstate->strict_comment;       break;
	case 2: attr = &pstate->decode_text_entities; break;
	case 3: attr = &pstate->keep_case;            break;
	case 4: attr = &pstate->xml_mode;             break;
	case 5: attr = &pstate->v2_compat;            break;
	case 6: attr = &pstate->pass_cbdata;          break;
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
	    *svp = SvREFCNT_inc(cb);
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
